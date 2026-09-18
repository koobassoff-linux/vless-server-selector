#!/usr/bin/env bash
# push-rsc.sh — auxiliary tool: deliver .rsc files to the RouterOS box and
# install each as a /system script named after the file basename.
# Standalone on purpose: never called from vless.sh.
#
# Transport: RouterOS has no sftp/scp server; RESTCONF file writes are gone
# in 7.24 (GET /rest/file works, PUT/POST -> 415/400; WebFig itself uploads
# via an encrypted /jsproxy), and feeding a .rsc through non-tty ssh stdin
# silently mangles comments/contexts. So we invert the connection instead:
# a throwaway python http.server serves the file on the LAN, the router
# pulls it with /tool fetch (byte-exact), we install via /file get contents.
#
# usage: ./push-rsc.sh [file.rsc ...]   (default: all *.rsc next to this script)

set -euo pipefail

declare SCRIPT_DIR
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR

source "${SCRIPT_DIR}/load-secret.sh"
source "${SCRIPT_DIR}/platform.sh"

require_cmds sshpass python3

if [[ -z "${SSH_PASS}" ]]; then
    echo "error: SSH_PASS is empty (check the secret file)" >&2
    exit 1
fi
if ! valid_host "${ROUTER_HOST}" || ! valid_port "${ROUTER_PORT}"; then
    echo "error: bad ROUTER_HOST/ROUTER_PORT in the secret file" >&2
    exit 1
fi

router_ssh() {
    # run one CLI command on the router, output to stdout
    SSHPASS="${SSH_PASS}" sshpass -e ssh -o ConnectTimeout=10 \
        -l admin -p "${ROUTER_PORT}" "${ROUTER_HOST}" "${1}"
}

# our own LAN IP as the router sees it (works on Linux and macOS alike:
# ask the router's conntrack about the source of this very ssh session;
# the table row looks like: "tcp 192.168.88.194 59822 192.168.88.1 1946 ...")
laptop_ip() {
    # fields around the match: ... srcip srcport dstip dstport state...
    router_ssh "/ip firewall connection print" \
        | awk -v port="${ROUTER_PORT}" '
            { for (i = 1; i <= NF; i++)
                if ($i == port && $(i-1) ~ /^[0-9.]+$/ && $(i-2) ~ /^[0-9]+$/ && $(i-3) ~ /^[0-9.]+$/) {
                    print $(i-3); exit
                }
            }'
}

HTTP_PID=""
http_stop() {
    [[ -n "${HTTP_PID}" ]] && kill "${HTTP_PID}" >/dev/null 2>&1
    HTTP_PID=""
}
trap http_stop EXIT

# serve directory $1 on a random high port, wait until the router can reach it
http_start() {
    local dir="${1}" lip="${2}"
    HTTP_PORT=$((20000 + RANDOM % 20000))
    python3 -m http.server "${HTTP_PORT}" --directory "${dir}" \
        >/dev/null 2>&1 &
    HTTP_PID=$!
    local i
    for i in 1 2 3 4 5; do
        if router_ssh "/tool fetch url=http://${lip}:${HTTP_PORT}/ dst-path=probe.tmp" \
            2>/dev/null | grep -q 'code: 200'; then
            router_ssh "/file remove probe.tmp" >/dev/null 2>&1 || true
            return 0
        fi
        sleep 1
    done
    return 1
}

push_one() {
    local file="${1}"
    local base name rc=0 dir lip

    if [[ ! -f "${file}" ]]; then
        echo "failed: no such file: ${file}" >&2
        return 1
    fi
    base="$(basename "${file}")"
    dir="$(dirname "${file}")"
    name="${base%.rsc}"
    if [[ ! "${name}" =~ ${NAME_RE} ]]; then
        echo "failed: bad script name '${name}' (allowed: [A-Za-z0-9._-])" >&2
        return 1
    fi

    lip="$(laptop_ip)" || true
    if [[ -z "${lip}" ]]; then
        echo "failed: cannot learn our LAN IP from the router's conntrack" >&2
        return 1
    fi

    if ! http_start "${dir}" "${lip}"; then
        echo "failed: router cannot reach our http server on ${lip}:${HTTP_PORT} (firewall?)" >&2
        http_stop
        return 1
    fi

    # pull the file to the router's RAM disk
    if ! router_ssh "/tool fetch url=http://${lip}:${HTTP_PORT}/${base} dst-path=${base}" \
        | grep -q 'code: 200'; then
        echo "failed: ${base}: /tool fetch from http://${lip}:${HTTP_PORT}" >&2
        http_stop
        return 1
    fi
    http_stop

    # install (add-or-update) and drop the uploaded file; one CLI line
    local install=":if ([:len [/system script find name=${name}]] > 0) do={ /system script set [/system script find name=${name}] source=[/file get [/file find name=${base}] contents] } else={ /system script add name=${name} source=[/file get [/file find name=${base}] contents] }; /file remove [/file find name=${base}]"
    if ! router_ssh "${install}"; then
        echo "failed: ${base}: install command" >&2
        router_ssh "/file remove [/file find name=${base}]" >/dev/null 2>&1 || true
        return 1
    fi

    # RouterOS CLI exits 0 even on syntax errors, so verify by output
    if ! router_ssh "/system script print where name=${name}" | grep -q "name=\"${name}\""; then
        echo "failed: ${base}: not present in /system script after install" >&2
        rc=1
    fi
    return "${rc}"
}

main() {
    local files=() file failed=0

    if [[ $# -gt 0 ]]; then
        files=("$@")
    else
        local f
        for f in "${SCRIPT_DIR}"/*.rsc; do
            [[ -e "${f}" ]] && files+=("${f}")
        done
    fi
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "nothing to do: no .rsc files given and none next to ${0}" >&2
        exit 1
    fi

    for file in "${files[@]}"; do
        if push_one "${file}"; then
            echo "ok: $(basename "${file}")"
        else
            failed=1
        fi
    done
    exit "${failed}"
}

main "$@"
