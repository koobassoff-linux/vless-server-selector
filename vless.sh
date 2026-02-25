#!/usr/bin/env bash

set -a FILE_CACHE
read_file_from_cache() {
    local file="${1}"

    while IFS= read -r line; do
        FILE_CACHE+=("$line")
    done < "$file"
}

parse_vless_strings() {
    local vless_strings=("$@")
    local json_array=()

    for vless_string in "${vless_strings[@]}"; do
        if [[ $vless_string != vless://* ]]; then
            continue
        fi
        json_obj=$(echo "$vless_string" | awk -F '[@?:#]' '
        {
            uuid = $2
            gsub ("/", "", uuid)
            host = $3

            cmd = "ping -c 2 " host " | grep 'rtt' "
            cmd | getline result
            close(cmd)

            json = "{\"uuid\":\"" uuid "\",\"host\":\"" host "\",\"port\":\"" $4 "\",\"ping\":\"" result "\""
            if (length($5) > 0) {
                split($5, params, "&")
                for (i in params) {
                    split(params[i], kv, "=")
                    if (length(kv[2]) != 0) {
                        json = json ",\"" kv[1] "\":\"" kv[2] "\""
                    }
                }
            }
            if ($6 != "") {
                json = json ",\"fragment\":\"" $6 "\""
            }
            json = json "}"
            print json
        }')

        json_array+=("$json_obj")
    done
    output_data=$(echo "${json_array[*]}" | sed 's/}\s*{/},{/g')

    echo "[${output_data[*]}]"
}

get_env() {
     echo "${1}" | jq -r .["${2}"]."${3}"
}

#get_env_section "${json}" 0
get_env_section() {
     echo "${1}" | jq -r .["${2}"]
}

main () {
    local readonly MY_VLESS_UID="${VLESS_UID}"  # from env?

    #curl -qs "https://proxyliberty.ru/connection/tunnel/${MY_VLESS_UID}" | base64 -d > "${MY_DATA_DIR}/vless-decoded.txt"
    #curl -qs "https://proxyliberty.ru/connection/subs/${MY_VLESS_UID}" | base64 -d >> "${MY_DATA_DIR}/vless-decoded.txt"
    #curl -qs "https://proxyliberty.ru/connection/test_proxies_subs/${MY_VLESS_UID}" | base64 -d >> "${MY_DATA_DIR}/vless-decoded.txt"

    local readonly MY_DATA_DIR="."  # from env?
    read_file_from_cache "${MY_DATA_DIR}/vless-decoded.txt"

    local json=$(parse_vless_strings "${FILE_CACHE[@]}")
    echo "${json}" | jq -cr '[.[] | {index: .i, host: .host, ping: .ping}] | to_entries[] | "\(.key) \(.value.host) \(.value.ping)"'

    echo "select server:"
    local INDEX
    read INDEX

    local readonly REMOTE_ADDRESS=$(get_env "${json}" "${INDEX}" "host")
    local readonly REMOTE_PORT=$(get_env "${json}" "${INDEX}" "port")
    local readonly ID=$(get_env "${json}" "${INDEX}" "uuid")
    local readonly SERVER_NAME=$(get_env "${json}" "${INDEX}" "sni")
    local readonly SHORT_ID=$(get_env "${json}" "${INDEX}" "sid")
    local readonly PUBLIC_KEY=$(get_env "${json}" "${INDEX}" "pbk")

    local readonly CMD_ENV_SET=$(echo "\$updateVlessSettings argArea="vless1" argID=${ID} argPbk=${PUBLIC_KEY} argRA=${REMOTE_ADDRESS}\
        argRP=${REMOTE_PORT} argSN=${SERVER_NAME} argSID=${SHORT_ID}")
    local readonly CMD_CONTAINER_RESTART=$(echo "; :foreach container in=[/container find] do={/container stop \$container; /container start \$container}")

    # ssh -l admin 192.168.88.1 -p 1946 "${CMD_ENV_SET}${CMD_CONTAINER_RESTART}"
}


main "${@}"
