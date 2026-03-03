#!/bin/env bash

source common.sh

#usage: asn-get.sh [domain.com][...]

while [ "$#" -gt 0 ]; do
	URL="${1}"

	IP=$(resolveip -s "${URL}")
	DESCR=$(curl -sL "ip.guide/${IP}")

	jq -n --argjson data "${DESCR}" '$data.network.autonomous_system.asn'

	shift
done

