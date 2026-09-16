#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by the sourcing script
# Platform-dependent knobs (Linux/macOS). Source this file, do not execute it.

PLATFORM_OS=$(uname -s)

case "${PLATFORM_OS}" in
    Darwin)
        # BSD ping: -W is in milliseconds
        PING_WAIT=(-W 2000)
        PING_WAIT_SHORT="-W 1000"
        ;;
    *)
        # Linux iputils ping: -W is in seconds
        PING_WAIT=(-W 2)
        PING_WAIT_SHORT="-W 1"
        ;;
esac

# base64 decode flag: GNU coreutils and macOS 13+ use -d, older BSD use -D
if base64 -d </dev/null >/dev/null 2>&1; then
    B64_D=(-d)
else
    B64_D=(-D)
fi

# ping summary line: Linux prints "rtt min/avg/max/mdev",
# BSD/macOS prints "round-trip min/avg/max/stddev";
# both split by "/" with avg at the same position
RTT_PATTERN="rtt|round-trip"

# require_cmds cmd [cmd...] — die listing every missing tool
require_cmds() {
    local cmd missing=""
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [[ -n "${missing}" ]]; then
        echo "error: missing required tools:${missing}" >&2
        exit 1
    fi
}

# Optional tools: HAVE_* flags
HAVE_FZF=0
if command -v fzf >/dev/null 2>&1; then
    HAVE_FZF=1
fi

# Validators — return 0 if the value is safe to use; patterns kept in
# variables for bash 3.2 compatibility ([[ x =~ $re ]] must be unquoted)
readonly HOST_RE='^[A-Za-z0-9][A-Za-z0-9.-]*$'
readonly PARAM_RE='^[A-Za-z0-9._:%+=/-]*$'
readonly URL_RE='^https?://[A-Za-z0-9._~:/?#@!$&*+,;=%-]+$'
readonly NAME_RE='^[A-Za-z0-9._-]+$'

valid_host() { [[ "${1}" =~ ${HOST_RE} ]]; }
valid_param() { [[ "${1}" =~ ${PARAM_RE} ]]; }
valid_url() { [[ "${1}" =~ ${URL_RE} ]]; }
valid_port() {
    [[ "${1}" =~ ^[0-9]+$ ]] && (( 10#${1} >= 1 && 10#${1} <= 65535 ))
}
