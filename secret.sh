#!/usr/bin/env bash

# Subscriptions: one entry per line, format "name|url".
#   name — shown in the selection menu and used for the cache file
#          "<name>-decoded.txt"; keep it a simple slug ([A-Za-z0-9._-]),
#          no '|', spaces or slashes.
#   url  — plain base64 subscription or an Xray config bundle (JSON);
#          vless.sh detects the format automatically by the first byte.
# To add a subscription, just append a line to the array; to start the
# script with a preset choice, run it as: SUBS=<name> ./vless.sh
# First entry is the legacy base64 subs, second is the Xray bundle
# (converted by sub-adapter.sh).
readonly SUBS_LIST=(
    "Provider1|https://"
    "Provider2|https://"
)


readonly SSH_PASS=${SSH_PASS:-""}
readonly ROUTER_HOST=${ROUTER_HOST:-""}
readonly ROUTER_PORT=${ROUTER_PORT:-""}
