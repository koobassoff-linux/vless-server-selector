#!/bin/env bash

source common.sh

#usage: asn-get.sh [asn-number][...]

GATEWAY="${GATEWAY:-"172.17.0.3"}"
FILE_OUT="asns.rsc"

while [ "$#" -gt 0 ]; do
    echo "Processing argument: $1"
    ASN="${1}"
    asn_ip_addresses=$(whois -h whois.radb.net "!gAS${ASN}" | grep -oP '(\d+\.\d+\.\d+\.\d+/\d+)' | sort -u)
    if [[ -z "$asn_ip_addresses" ]]; then
        echo "no ip for ASN ${ASN}!"
    else
        ip_addresses+="\n${asn_ip_addresses}"
    fi
    shift
done

summed=$(echo -e "${ip_addresses}" | routesum)

: > "${FILE_OUT}"
for ip in $summed; do
    echo "/ip route add dst-address=${ip} gateway=${GATEWAY}" comment="ASN" >> "${FILE_OUT}"
done

echo "done, see ${FILE_OUT}"