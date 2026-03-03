#/bin/env bash

check_debug () {
    if [[ -n "${USE_DEBUG}" && "${USE_DEBUG}" != "0" ]]; then
        set -o xtrace
    else
        set +x
    fi
}

exit_if_not_root () {
    local USER=$(whoami)

    if [[ ${USER} != "root" ]] ; then
        printf "use sudo, Luke!\n"
        exit 1
    fi
}

get_netrc_val() {
    local MACHINE=$1
    local FIELD=$2
    local DIRNAME="${SUDO_USER:-$(whoami)}"
    awk -v host="${MACHINE}" -v fld="${FIELD}" \
    	'
        	$1 == "machine" && $2 == host { found=1; next}
        	found && $1 == fld { print $2; exit}
        	$1 == "machine" { found = 0 }
    	' \
    	"/home/${DIRNAME}/.netrc"
}


check_debug