#!/usr/bin/env bash
set -euo pipefail

declare SCRIPT_DIR
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR

source "${SCRIPT_DIR}/load-secret.sh"
source "${SCRIPT_DIR}/platform.sh"
source "${SCRIPT_DIR}/vless-lib.sh"

require_cmds curl jq awk base64 column sshpass

validate_secrets

select_subscription() {
    # fills globals SUBS_NAME SUBS_URL; SUBS="name" env skips the prompt
    # (SUBS_LIST entries are pre-validated by validate_secrets)
    local entry=""

    if [[ -n "${SUBS:-}" ]]; then
        resolve_subscription "${SUBS}" || exit 1
        return 0
    fi
    if (( ${#SUBS_LIST[@]} == 1 )); then
        resolve_subscription "${SUBS_LIST[0]%%|*}" || exit 1
        return 0
    fi
    if (( HAVE_FZF )); then
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

        set_globals_from_json "${json}" "${INDEX}"

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

        fetch_subscription "${MY_DATA_DIR}" "${SUBS_NAME}" "${SUBS_URL}" || exit 1

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
