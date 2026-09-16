#!/usr/bin/env bash
# Shared secret bootstrap for vless-server-selector scripts.
# Sets SECRET_FILE and sources it; expects SCRIPT_DIR from the caller.

source "$(dirname "${BASH_SOURCE[0]}")/once.sh"
once "${BASH_SOURCE[0]}"

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
