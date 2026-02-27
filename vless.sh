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
            printf("Processing %s.......\r", host) | "cat>&2"
            cmd = "ping -c 1 " host " 2>/dev/null | grep 'rtt' "
            cmd | getline result
            close(cmd)
            if (result == "") {
                result_avg = "99999999"
            } else {
                split(result, result_parts, "/")
                result_avg = result_parts[6]
            }
            json = "{\"uuid\":\"" uuid "\",\"host\":\"" host "\",\"port\":\"" $4 "\",\"ping\":\""result_avg "\""
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

get_env_from_array() {
     echo "${1}" | jq -r .["${2}"]."${3}"
}

get_env() {
     echo "${1}" | jq -r ."${2}"
}

main () {
    local readonly MY_DATA_DIR="${DATA_DIR:-.}"

    if [[ ! -f "${MY_DATA_DIR}/vless-decoded.txt" ]]; then
        if [[ -z "${VLESS_UID}" ]]; then
            echo "error: specify VLESS_UID"
            exit 1
        fi
        echo "getting vless subs"
        curl -qs "https://proxyliberty.ru/connection/tunnel/${VLESS_UID}" | base64 -d > "${MY_DATA_DIR}/vless-decoded.txt"
        echo "getting vless-obhod subs"
        echo -e "\n" >> "${MY_DATA_DIR}/vless-decoded.txt"
        echo "getting white-lists subs"
        echo -e "\n" >> "${MY_DATA_DIR}/vless-decoded.txt"
        curl -qs "https://proxyliberty.ru/connection/test_proxies_subs/${VLESS_UID}" | base64 -d >> "${MY_DATA_DIR}/vless-decoded.txt"

        sed -i '/^$/d' "${MY_DATA_DIR}/vless-decoded.txt"
    else
        echo "using cache from ${MY_DATA_DIR}/vless-decoded.txt"
    fi

    read_file_from_cache "${MY_DATA_DIR}/vless-decoded.txt"

    local json=$(parse_vless_strings "${FILE_CACHE[@]}")
    echo "${json}" | jq -cr '[.[] | {index: .i, host: .host, ping: .ping, fragment: .fragment}] | to_entries[]
        | "\(.key) \(.value.host) \(.value.fragment) \(.value.ping)"'\
        | column -t

    echo "select server, send 'a' for fastest:"
    local INDEX
    read INDEX
    if [[ "${INDEX}" -eq "a" ]]; then
        local readonly FASTEST=$(echo "${json}" | jq -r 'sort_by(.ping)'.[0])
        local readonly REMOTE_ADDRESS=$(get_env "${FASTEST}" "host")

        local readonly REMOTE_PORT=$(   get_env    "${FASTEST}" "port")
        local readonly ID=$(            get_env    "${FASTEST}" "uuid")
        local readonly SERVER_NAME=$(   get_env    "${FASTEST}" "sni")
        local readonly SHORT_ID=$(      get_env    "${FASTEST}" "sid")
        local readonly PUBLIC_KEY=$(    get_env    "${FASTEST}" "pbk")

        ping -c5 "${REMOTE_ADDRESS}"

        echo "sure?"
        local YEP
        read YEP
        if [[ "${YEP}" != "y" ]]; then
            exit
        fi
    else
        local readonly REMOTE_ADDRESS=$(    get_env_from_array "${json}" "${INDEX}" "host")
        local readonly REMOTE_PORT=$(       get_env_from_array "${json}" "${INDEX}" "port")
        local readonly ID=$(                get_env_from_array "${json}" "${INDEX}" "uuid")
        local readonly SERVER_NAME=$(       get_env_from_array "${json}" "${INDEX}" "sni")
        local readonly SHORT_ID=$(          get_env_from_array "${json}" "${INDEX}" "sid")
        local readonly PUBLIC_KEY=$(        get_env_from_array "${json}" "${INDEX}" "pbk")
    fi

    local readonly CMD_ENV_SET=$(echo "\$updateVlessSettings argArea="vless1" argID=${ID} argPbk=${PUBLIC_KEY} argRA=${REMOTE_ADDRESS}\
        argRP=${REMOTE_PORT} argSN=${SERVER_NAME} argSID=${SHORT_ID}")
    local readonly CMD_CONTAINER_RESTART=$(echo "; :foreach container in=[/container find] do={/container stop \$container; /container start \$container}")

    ssh -l admin 192.168.88.1 -p 1946 "${CMD_ENV_SET}" #${CMD_CONTAINER_RESTART}"
}


main "${@}"
