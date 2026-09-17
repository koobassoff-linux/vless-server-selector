#!/usr/bin/env bash
# shellcheck disable=SC2034  # some globals are consumed by the sourcing script
# vless-lib.sh — shared logic for vless.sh (interactive) and watchdog.sh (cron).
# No UI, no main; entry scripts call require_cmds/validate_secrets themselves.
# Expects from the caller: SCRIPT_DIR set, load-secret.sh and platform.sh sourced.

source "$(dirname "${BASH_SOURCE[0]}")/once.sh"
once "${BASH_SOURCE[0]}"

readonly CURL_OPTS=(-fsS --connect-timeout 5 --max-time 30)

declare -a FILE_CACHE JSON_ARRAY
declare SUBS_NAME="" SUBS_URL=""
# filled by set_globals_from_json()
declare REMOTE_ADDRESS="" REMOTE_PORT="" ID="" SERVER_NAME="" SHORT_ID="" PUBLIC_KEY=""

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

resolve_subscription() {
    # $1 = name from SUBS_LIST; fills SUBS_NAME SUBS_URL; returns 1 if unknown
    local line
    for line in "${SUBS_LIST[@]}"; do
        if [[ "${line%%|*}" == "${1}" ]]; then
            SUBS_NAME="${line%%|*}"
            SUBS_URL="${line#*|}"
            return 0
        fi
    done
    echo "error: unknown subscription '${1}'" >&2
    return 1
}

fetch_subscription() {
    # $1=data_dir $2=name $3=url; ensures "<name>-decoded.txt" cache exists;
    # the interactive "use cache?" prompt stays in the caller
    local data_dir="${1}" name="${2}" url="${3}"
    local cache="${data_dir}/${name}-decoded.txt"
    if [[ -s "${cache}" ]]; then
        return 0
    fi

    echo "getting vless subs"
    local raw_tmp="${cache}.raw.tmp" cache_tmp="${cache}.tmp"
    if curl "${CURL_OPTS[@]}" "${url}" -o "${raw_tmp}" && [[ -s "${raw_tmp}" ]]; then
        # JSON array => Xray config bundle, needs the adapter; plain => base64
        if [[ "$(head -c 1 "${raw_tmp}")" == "[" ]]; then
            "${SCRIPT_DIR}/sub-adapter.sh" < "${raw_tmp}" > "${cache_tmp}"
        else
            base64 "${B64_D[@]}" < "${raw_tmp}" > "${cache_tmp}"
        fi && mv "${cache_tmp}" "${cache}"
    fi
    rm -f "${raw_tmp}"
    if [[ ! -f "${cache}" ]]; then
        rm -f "${cache_tmp}"
        echo "error: failed to fetch subscription" >&2
        return 1
    fi
    return 0
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

set_globals_from_json() {
    # $1 = sorted json array, $2 = index; fills REMOTE_*/ID/SERVER_NAME/SHORT_ID/PUBLIC_KEY
    local json="${1}" index="${2}"
    REMOTE_ADDRESS=$( get_env_from_array "${json}" "${index}" "host")
    REMOTE_PORT=$(    get_env_from_array "${json}" "${index}" "port")
    ID=$(             get_env_from_array "${json}" "${index}" "uuid")
    SERVER_NAME=$(    get_env_from_array "${json}" "${index}" "sni")
    SHORT_ID=$(       get_env_from_array "${json}" "${index}" "sid")
    PUBLIC_KEY=$(     get_env_from_array "${json}" "${index}" "pbk")
}

check_youtube() {
    # --max-time after CURL_OPTS overrides its 30s (curl: last occurrence wins);
    # no -L on purpose: a redirect means "not a clean youtube answer"
    curl "${CURL_OPTS[@]}" --max-time 10 -o /dev/null "${YOUTUBE_URL:-https://www.youtube.com/generate_204}"
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

    # no -r here: apply_to_router may be called several times in one shell
    declare CMD_ENV_SET="/system/script/run env_change; \$updateVlessSettings argArea=\"vless\"\
        argID=\"${ID}\" argPbk=\"${PUBLIC_KEY}\" argRA=\"${REMOTE_ADDRESS}\" argRP=\"${REMOTE_PORT}\"\
        argSN=\"${SERVER_NAME}\" argSID=\"${SHORT_ID}\""

    declare CMD_CONTAINER_RESTART="; :foreach container in=[/container find] do={/container stop \$container; /container start \$container}"

    if ! SSHPASS="${SSH_PASS}" sshpass -e ssh -l admin "${ROUTER_HOST}" -p "${ROUTER_PORT}" "${CMD_ENV_SET} ${CMD_CONTAINER_RESTART}"; then
        echo "warning: router apply failed" >&2
        return 1
    fi
}
