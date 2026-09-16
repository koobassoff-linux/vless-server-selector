#!/usr/bin/env bash
# push-rsc.sh — auxiliary tool: upload .rsc files to the RouterOS box and
# install each as a /system script named after the file basename.
# Standalone on purpose: never called from vless.sh.
#
# usage: ./push-rsc.sh [file.rsc ...]   (default: all *.rsc next to this script)

set -euo pipefail

declare SCRIPT_DIR
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR

source "${SCRIPT_DIR}/load-secret.sh"
source "${SCRIPT_DIR}/platform.sh"

require_cmds sshpass

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
    SSHPASS="${SSH_PASS}" sshpass -e ssh -l admin -p "${ROUTER_PORT}" "${ROUTER_HOST}" "${1}"
}

push_one() {
    local file="${1}"
    local base name rc=0

    if [[ ! -f "${file}" ]]; then
        echo "failed: no such file: ${file}" >&2
        return 1
    fi
    base="$(basename "${file}")"
    name="${base%.rsc}"
    if [[ ! "${name}" =~ ${NAME_RE} ]]; then
        echo "failed: bad script name '${name}' (allowed: [A-Za-z0-9._-])" >&2
        return 1
    fi

    if ! SSHPASS="${SSH_PASS}" sshpass -e sftp -P "${ROUTER_PORT}" -b - "admin@${ROUTER_HOST}" <<< "put ${file}" >/dev/null; then
        echo "failed: ${base}: sftp upload" >&2
        return 1
    fi

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
