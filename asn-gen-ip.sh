#!/usr/bin/env bash
set -eu

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

#usage: asn-gen-ip.sh [asn-number][...]

GATEWAY="${GATEWAY:-"172.17.0.3"}"
FILE_OUT="${FILE_OUT:-"asns.rsc"}"

ip_addresses=""
while [ "$#" -gt 0 ]; do
    echo "Processing argument: $1"
    if [[ ! "${1}" =~ ^[0-9]+$ ]]; then
        echo "not an ASN number: ${1}" >&2
        shift
        continue
    fi
    ASN="${1}"
    # grep -oE instead of -oP: BSD grep (macOS) has no PCRE
    asn_ip_addresses=$(whois -h whois.radb.net "!gAS${ASN}" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | sort -u) || asn_ip_addresses=""
    if [[ -z "${asn_ip_addresses}" ]]; then
        echo "no ip for ASN ${ASN}!" >&2
    else
        ip_addresses+="${asn_ip_addresses}"$'\n'
    fi
    shift
done

# printf instead of echo -e: portable
summed=$(printf '%s' "${ip_addresses}" | routesum)

: > "${FILE_OUT}"
# shellcheck disable=SC2086  # word splitting on routesum output is intended
for ip in ${summed}; do
    echo "/ip route add dst-address=${ip} gateway=${GATEWAY}" comment="ASN" >> "${FILE_OUT}"
done

echo "done, see ${FILE_OUT}"
