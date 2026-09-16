#!/usr/bin/env bash
# once.sh — loud double-source guard for sourced libraries.
# usage at the top of a library:
#   source "$(dirname "${BASH_SOURCE[0]}")/once.sh"
#   once "${BASH_SOURCE[0]}"

once() {
    local src="${1}" marker
    marker="_LOADED_${src##*/}"
    marker="${marker//[-.]/_}"
    if [[ -n "${!marker:-}" ]]; then
        echo "BUG: ${src} sourced twice — fix the include graph" >&2
        exit 1
    fi
    printf -v "$marker" '%s' 1
    readonly "$marker"
}
