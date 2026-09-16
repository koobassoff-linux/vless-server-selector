#!/usr/bin/env bash
set -eu

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

#usage: asn-get.sh [domain.com][...]

while [ "$#" -gt 0 ]; do
	URL="${1}"

	if ! IP=$(resolveip -s "${URL}"); then
		echo "resolve error: ${URL}" >&2
		shift
		continue
	fi

	if ! DESCR=$(curl -sL "ip.guide/${IP}"); then
		echo "ip.guide error" >&2
		shift
		continue
	fi
	jq -n --argjson data "${DESCR}" '$data.network.autonomous_system.asn'

	shift
done
