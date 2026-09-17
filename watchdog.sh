#!/usr/bin/env bash
# watchdog.sh — cron helper: switch vless server when youtube goes down.
# install: crontab -e, then:
#   * * * * * /path/to/watchdog.sh >> ~/.local/state/vless-watchdog/watchdog.log 2>&1
# env: WD_STATE_DIR, YOUTUBE_URL (see vless-lib.sh)

set -euo pipefail

# cron gives a bare PATH; brew tools on macOS live here
PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin"
export PATH

declare SCRIPT_DIR
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR

source "${SCRIPT_DIR}/load-secret.sh"
source "${SCRIPT_DIR}/platform.sh"
source "${SCRIPT_DIR}/vless-lib.sh"

require_cmds curl jq awk base64 sshpass ping
validate_secrets

declare WD_STATE_DIR="${WD_STATE_DIR:-${HOME}/.local/state/vless-watchdog}"
mkdir -p "${WD_STATE_DIR}"
declare -r LOCK="${WD_STATE_DIR}/lock" TRIED="${WD_STATE_DIR}/tried"

log() { echo "$(date '+%F %T') $*"; }

# one tick at a time: mkdir is atomic, stale locks (>10 min) get stolen
if ! mkdir "${LOCK}" 2>/dev/null; then
    find "${LOCK}" -maxdepth 0 -mmin +10 -exec rmdir {} \; 2>/dev/null || true
    mkdir "${LOCK}" 2>/dev/null || exit 0
fi
trap 'rmdir "${LOCK}" 2>/dev/null || true' EXIT

# router first: without it there is nothing to check or fix
if ! ping -c1 "${PING_WAIT[@]}" "${ROUTER_HOST}" >/dev/null 2>&1; then
    log "router down, nothing to do"
    exit 0
fi

if check_youtube; then
    rm -f "${TRIED}"
    exit 0
fi
log "youtube unreachable, looking for a server"

declare entry json count i host chosen
for entry in "${SUBS_LIST[@]}"; do
    resolve_subscription "${entry%%|*}" || continue

    if ! fetch_subscription "${WD_STATE_DIR}" "${SUBS_NAME}" "${SUBS_URL}"; then
        log "provider ${SUBS_NAME}: fetch failed, next"
        continue
    fi

    FILE_CACHE=()
    read_file_from_cache "${WD_STATE_DIR}/${SUBS_NAME}-decoded.txt"
    parse_vless_strings "${FILE_CACHE[@]}"
    count=${#JSON_ARRAY[@]}
    if (( count == 0 )); then
        log "provider ${SUBS_NAME}: parsed to 0 servers, next"
        continue
    fi
    json=$(printf '%s\n' "${JSON_ARRAY[@]}" | jq -sc 'sort_by(.ping | tonumber)')

    chosen=""
    for (( i = 0; i < count; i++ )); do
        host=$(get_env_from_array "${json}" "${i}" "host")
        if [[ -f "${TRIED}" ]] && grep -qxF "${host}" "${TRIED}"; then
            continue
        fi
        chosen="${i}"
        break
    done
    if [[ -z "${chosen}" ]]; then
        log "provider ${SUBS_NAME}: all servers tried, next"
        continue
    fi

    set_globals_from_json "${json}" "${chosen}"
    echo "${REMOTE_ADDRESS}" >> "${TRIED}"
    log "trying ${SUBS_NAME} ${REMOTE_ADDRESS} (index ${chosen})"

    if ! apply_to_router; then
        log "router apply failed, next"
        continue
    fi
    if check_youtube; then
        log "switched to ${REMOTE_ADDRESS} (${SUBS_NAME}), youtube OK"
        rm -f "${TRIED}"
        exit 0
    fi
    log "youtube still down via ${REMOTE_ADDRESS}"
done

log "all providers exhausted, waiting for recovery"
