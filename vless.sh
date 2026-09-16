#!/usr/bin/env bash
set -euo pipefail

declare SCRIPT_DIR
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR

# secrets live outside the repo; see secret.sh.example for the template
declare SECRET_FILE="${VLESS_SECRET_PATH:-${HOME}/.config/vless/secret.sh}"
if [[ ! -f "${SECRET_FILE}" ]]; then
    echo "error: no secret file at ${SECRET_FILE}" >&2
    echo "       copy secret.sh.example from the repo there and fill in values" >&2
    echo "       (or point VLESS_SECRET_PATH=<path> at it)" >&2
    exit 1
fi
# shellcheck source=/dev/null  # path is runtime-provided (VLESS_SECRET_PATH)
source "${SECRET_FILE}"
source "${SCRIPT_DIR}/platform.sh"

require_cmds curl jq awk base64 column sshpass

validate_secrets() {
    # fail fast on any bad value from secret.sh before touching the network
    local entry name url

    if [[ -z "${SSH_PASS}" ]]; then
        echo "error: SSH_PASS is empty (check secret.sh)" >&2
        exit 1
    fi
    if ! valid_host "${ROUTER_HOST}" || ! valid_port "${ROUTER_PORT}"; then
        echo "error: bad ROUTER_HOST/ROUTER_PORT in secret.sh" >&2
        exit 1
    fi
    if [[ -z "${SUBS_LIST[*]:-}" ]]; then
        echo "error: SUBS_LIST is empty (check secret.sh)" >&2
        exit 1
    fi
    for entry in "${SUBS_LIST[@]}"; do
        name="${entry%%|*}"
        url="${entry#*|}"
        if [[ "${entry}" != *"|"* ]] || ! [[ "${name}" =~ ${NAME_RE} ]] || ! valid_url "${url}"; then
            echo "error: bad SUBS_LIST entry '${entry}' (expected 'name|url', name: [A-Za-z0-9._-])" >&2
            exit 1
        fi
    done
}

validate_secrets

readonly CURL_OPTS=(-fsS --connect-timeout 5 --max-time 30)

declare -a FILE_CACHE JSON_ARRAY
declare SUBS_NAME="" SUBS_URL=""
# filled by choose_server()
declare REMOTE_ADDRESS="" REMOTE_PORT="" ID="" SERVER_NAME="" SHORT_ID="" PUBLIC_KEY=""

select_subscription() {
    # fills globals SUBS_NAME SUBS_URL; SUBS="name" env skips the prompt
    # (SUBS_LIST entries are pre-validated by validate_secrets)
    local entry=""

    if [[ -n "${SUBS:-}" ]]; then
        local line
        for line in "${SUBS_LIST[@]}"; do
            if [[ "${line%%|*}" == "${SUBS}" ]]; then
                entry="${line}"
                break
            fi
        done
        if [[ -z "${entry}" ]]; then
            echo "error: unknown subscription '${SUBS}'" >&2
            exit 1
        fi
    elif (( HAVE_FZF )); then
        entry=$(printf '%s\n' "${SUBS_LIST[@]}" | FZF_DEFAULT_OPTS="" FZF_DEFAULT_OPTS_FILE="" fzf --sync \
            --delimiter='|' --with-nth=1 --header 'subscription' --bind='start:last') \
            || { echo "aborted (fzf)"; exit 130; }
    else
        local i=0 line idx
        for line in "${SUBS_LIST[@]}"; do
            echo "${i}) ${line%%|*}"
            i=$(( i + 1 ))
        done
        echo "select subscription:"
        while true; do
            read -r idx || { echo "aborted (EOF)"; exit 130; }
            if [[ "${idx}" =~ ^[0-9]+$ ]] && (( 10#${idx} < ${#SUBS_LIST[@]} )); then
                entry="${SUBS_LIST[$(( 10#${idx} ))]}"
                break
            fi
            echo "invalid index '${idx}', valid: 0..$(( ${#SUBS_LIST[@]} - 1 ))"
        done
    fi

    SUBS_NAME="${entry%%|*}"
    SUBS_URL="${entry#*|}"
}

read_file_from_cache() {
    local file="${1}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        FILE_CACHE+=("$line")
    done < "$file"
}

parse_vless_strings() {
    # fills global JSON_ARRAY; no stdout output
    local vless_string json_obj
    JSON_ARRAY=()

    for vless_string in "$@"; do
        if [[ $vless_string != vless://* ]]; then
            continue
        fi

        json_obj=$(echo "$vless_string" | LC_ALL=C awk -F '[@?:#]' -v pw="${PING_WAIT_SHORT}" -v rttre="${RTT_PATTERN}" -v hostre="${HOST_RE}" '
        function esc(s) {
            gsub(/\\/, "\\\\", s)
            gsub(/"/, "\\\"", s)
            return s
        }
        BEGIN {
            for (i = 0; i < 256; i++) H2C[sprintf("%02X", i)] = sprintf("%c", i)
        }
        function urldecode(s,    i, out, c, hh) {
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                hh = substr(s, i + 1, 2)
                if (c == "%" && hh ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) {
                    out = out H2C[toupper(hh)]
                    i += 2
                } else {
                    out = out c
                }
            }
            return out
        }
        {
            uuid = esc(urldecode($2))
            gsub ("/", "", uuid)
            host = esc(urldecode($3))
            printf("Processing %s.......\r", host) | "cat>&2"
            result = ""
            if (host ~ hostre) {
                cmd = "ping -c1 " pw " " host " 2>/dev/null | grep -E \"" rttre "\" "
                cmd | getline result
                close(cmd)
            }
            if (result == "") {
                result_avg = "99999999"
            } else {
                split(result, result_parts, "/")
                result_avg = int(result_parts[5])
            }
            json = "{\"uuid\":\"" uuid "\",\"host\":\"" host "\",\"port\":\"" esc($4) "\",\"ping\":\""result_avg "\""
            if (length($5) > 0) {
                split($5, params, "&")
                for (i in params) {
                    split(params[i], kv, "=")
                    if (length(kv[2]) != 0) {
                        json = json ",\"" esc(kv[1]) "\":\"" esc(urldecode(kv[2])) "\""
                    }
                }
            }
            if ($6 != "") {
                json = json ",\"fragment\":\"" esc(urldecode($6)) "\""
            }
            json = json "}"
            print json
        }')

        [[ -n "${json_obj}" ]] && JSON_ARRAY+=("${json_obj}")
    done
    return 0
}

get_env_from_array() {
     echo "${1}" | jq -r ".[${2}].${3} // empty"
}

choose_server() {
    # $1 = sorted json array, $2 = server count, $3 = optional warning line
    # returns 0 = server chosen (globals filled), 100 = back to subscriptions
    local json="${1}" count="${2}"
    local warn="${3:-}"
    local FINISH=0 ping_ok=1

    while [[ ${FINISH} -ne 1 ]]; do
        local rows INDEX
        rows=$(echo "${json}" | jq -cr '[.[] | {host: .host, ping: .ping, fragment: .fragment}] | to_entries[]
            | [.key, .value.host, (if .value.fragment == "" then "-" else .value.fragment end), .value.ping] | @tsv')

        if (( HAVE_FZF )); then
            local out event
            local header=$'idx\thost\tfragment\tping  (esc = back)'
            [[ -n "${warn}" ]] && header+=$'\n'"${warn}"
            out=$(printf '%s\n' "${rows}" | FZF_DEFAULT_OPTS="" FZF_DEFAULT_OPTS_FILE="" fzf --sync \
                --tac --tabstop=1 --delimiter='\t' --nth=1,3 \
                --header "${header}" \
                --expect=esc --bind='start:last') \
                || { echo "aborted (fzf)"; exit 130; }
            event=$(printf '%s\n' "${out}" | head -1)
            if [[ "${event}" == "esc" ]]; then
                echo "back to subscriptions"
                return 100
            fi
            INDEX=$(printf '%s\n' "${out}" | sed -n '2p' | cut -f1)
        else
            [[ -n "${warn}" ]] && echo "${warn}"
            printf '%s\n' "${rows}" | column -t -s $'\t'
            echo "select server (empty = back):"
            while true; do
                read -r INDEX || { echo "aborted (EOF)"; exit 130; }
                if [[ -z "${INDEX}" ]]; then
                    echo "back to subscriptions"
                    return 100
                fi
                if [[ "${INDEX}" =~ ^[0-9]+$ ]]; then
                    INDEX=$(( 10#${INDEX} ))
                    if (( INDEX < count )); then
                        break
                    fi
                fi
                echo "invalid index '${INDEX}', valid: 0..$(( count - 1 ))"
            done
        fi

        REMOTE_ADDRESS=$(    get_env_from_array "${json}" "${INDEX}" "host")
        REMOTE_PORT=$(       get_env_from_array "${json}" "${INDEX}" "port")
        ID=$(                get_env_from_array "${json}" "${INDEX}" "uuid")
        SERVER_NAME=$(       get_env_from_array "${json}" "${INDEX}" "sni")
        SHORT_ID=$(          get_env_from_array "${json}" "${INDEX}" "sid")
        PUBLIC_KEY=$(        get_env_from_array "${json}" "${INDEX}" "pbk")

        if ping -c5 "${PING_WAIT[@]}" "${REMOTE_ADDRESS}"; then
            ping_ok=1
        else
            ping_ok=0
            echo "host ${REMOTE_ADDRESS} unreachable, try another choice"
        fi

        echo "sure?"
        local YEP
        read -r YEP || { echo "aborted (EOF)"; exit 130; }
        if [[ "${YEP}" == "y" ]]; then
            FINISH=1
        else
            echo "next choice"
            (( ping_ok )) || warn="ERROR: host ${REMOTE_ADDRESS} unreachable"
        fi
    done
}

check_youtube() {
    # --max-time after CURL_OPTS overrides its 30s (curl: last occurrence wins);
    # no -L on purpose: a redirect means "not a clean youtube answer"
    curl "${CURL_OPTS[@]}" --max-time 10 -o /dev/null "https://www.youtube.com/generate_204"
}

apply_to_router() {
    # pushes the chosen server (globals) to the router; returns 1 on ssh failure
    if ! valid_host "${REMOTE_ADDRESS}"; then
        echo "error: suspicious host from subscription: '${REMOTE_ADDRESS}'" >&2
        exit 1
    fi

    local _var _val
    for _var in ID PUBLIC_KEY REMOTE_PORT SERVER_NAME SHORT_ID; do
        _val="${!_var}"
        if ! valid_param "${_val}"; then
            echo "error: suspicious ${_var} from subscription: '${_val}'" >&2
            exit 1
        fi
    done

    declare -r CMD_ENV_SET="/system/script/run env_change; \$updateVlessSettings argArea=\"vless\"\
        argID=\"${ID}\" argPbk=\"${PUBLIC_KEY}\" argRA=\"${REMOTE_ADDRESS}\" argRP=\"${REMOTE_PORT}\"\
        argSN=\"${SERVER_NAME}\" argSID=\"${SHORT_ID}\""

    declare -r CMD_CONTAINER_RESTART="; :foreach container in=[/container find] do={/container stop \$container; /container start \$container}"

    if ! SSHPASS="${SSH_PASS}" sshpass -e ssh -l admin "${ROUTER_HOST}" -p "${ROUTER_PORT}" "${CMD_ENV_SET} ${CMD_CONTAINER_RESTART}"; then
        echo "warning: router apply failed" >&2
        return 1
    fi
}

main () {
    declare -r MY_DATA_DIR="${DATA_DIR:-.}"
    local file_cache_name rc json count

    while true; do
        select_subscription
        file_cache_name="${SUBS_NAME}-decoded.txt"
        echo "subscription: ${SUBS_NAME}"

        if [[ -f "${MY_DATA_DIR}/${file_cache_name}" ]]; then
            echo "use cache from ${MY_DATA_DIR}/${file_cache_name} ?"
            local YEP
            read -r YEP || { echo "aborted (EOF)"; exit 130; }
            if [[ "${YEP}" != "y" ]]; then
                rm "${MY_DATA_DIR}/${file_cache_name}"
            fi
        fi

        if [[ ! -f "${MY_DATA_DIR}/${file_cache_name}" ]]; then

            echo "getting vless subs"

            local raw_tmp="${MY_DATA_DIR}/${file_cache_name}.raw.tmp"
            local cache_tmp="${MY_DATA_DIR}/${file_cache_name}.tmp"
            if curl "${CURL_OPTS[@]}" "${SUBS_URL}" -o "${raw_tmp}" && [[ -s "${raw_tmp}" ]]; then
                # JSON array => Xray config bundle, needs the adapter; plain => base64
                if [[ "$(head -c 1 "${raw_tmp}")" == "[" ]]; then
                    "${SCRIPT_DIR}/sub-adapter.sh" < "${raw_tmp}" > "${cache_tmp}"
                else
                    base64 "${B64_D[@]}" < "${raw_tmp}" > "${cache_tmp}"
                fi && mv "${cache_tmp}" "${MY_DATA_DIR}/${file_cache_name}"
            fi
            rm -f "${raw_tmp}"
            if [[ ! -f "${MY_DATA_DIR}/${file_cache_name}" ]]; then
                rm -f "${cache_tmp}"
                echo "error: failed to fetch subscription" >&2
                exit 1
            fi

        fi

        FILE_CACHE=()
        read_file_from_cache "${MY_DATA_DIR}/${file_cache_name}"

        parse_vless_strings "${FILE_CACHE[@]}"
        count=${#JSON_ARRAY[@]}
        if (( count == 0 )); then
            echo "error: subscription parsed to 0 servers" >&2
            exit 1
        fi
        json=$(printf '%s\n' "${JSON_ARRAY[@]}" | jq -sc 'sort_by(.ping | tonumber)')

        local subs_done=0 warn=""
        while true; do
            rc=0
            choose_server "${json}" "${count}" "${warn}" || rc=$?
            if (( rc == 100 )); then
                break
            elif (( rc != 0 )); then
                exit "${rc}"
            fi
            warn=""

            if ! apply_to_router; then
                echo "error: router apply failed (this is serious — check router availability/credentials)" >&2
                read -r -p "press Enter to pick another server... " _ || { echo "aborted (EOF)"; exit 130; }
                continue
            fi
            if check_youtube; then
                echo "youtube: OK"
                subs_done=1
                break
            fi
            warn="WARNING: youtube unreachable via ${REMOTE_ADDRESS}"
        done
        if (( subs_done )); then
            break
        fi
    done
}


main "${@}"
