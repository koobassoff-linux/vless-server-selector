#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/once.sh"
once "${BASH_SOURCE[0]}"

check_debug () {
    if [[ -n "${USE_DEBUG:-}" && "${USE_DEBUG:-}" != "0" ]]; then
        set -o xtrace
    else
        set +x
    fi
}

check_debug

exit_if_not_root () {
    local user_name
    user_name="$(id -un)"

    if [[ ${user_name} != "root" ]] ; then
        printf "use sudo, Luke!\n" >&2
        exit 1
    fi
}

get_netrc_val() {
    local MACHINE="${1:-}"
    local FIELD="${2:-}"
    local DIRNAME="${SUDO_USER:-$(whoami)}"
    local netrc_file

    if [[ ! "${DIRNAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "get_netrc_val: bad user name" >&2
        return 0
    fi
    # ~-expansion finds the home on both Linux (/home) and macOS (/Users);
    # getent would be Linux-only
    # shellcheck disable=SC2086  # ~ must stay unquoted to expand
    eval netrc_file="~${DIRNAME}/.netrc"
    if [[ ! -f "${netrc_file}" ]]; then
        echo "get_netrc_val: no ${netrc_file}" >&2
        return 0
    fi
    awk -v host="${MACHINE}" -v fld="${FIELD}" \
    	'
        	$1 == "machine" && $2 == host { found=1; next}
        	found && $1 == fld { print $2; exit}
        	$1 == "machine" { found = 0 }
    	' \
    	"${netrc_file}"
}

