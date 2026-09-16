#!/usr/bin/env bash
set -euo pipefail
# sub-adapter.sh — convert an Xray config bundle (JSON array on stdin,
# connliberty.com format) into plain "vless://uuid@host:port?params#remark"
# lines, the same format the legacy base64 subscription provides.
# Non-vless outbounds (hysteria, shadowsocks, ...) are skipped with a
# warning; freedom/blackhole are infra outbounds and not counted.
# Duplicate servers (same address:port across bundles) are deduplicated,
# preferring the bundle with a specific remark over the "Авто" balancer one.

input=$(cat)

if ! jq -e 'type == "array"' >/dev/null <<<"${input}"; then
    echo "sub-adapter: error: expected a JSON array on stdin" >&2
    exit 1
fi

skipped=$(jq -r '
    [ .[] | .outbounds[]?
      | select(.protocol as $p | ["vless", "freedom", "blackhole"] | index($p) | not)
      | .protocol ]
    | group_by(.) | map("\(.[0]) x\(length)") | join(", ")' <<<"${input}")
if [[ -n "${skipped}" ]]; then
    echo "sub-adapter: skipped non-vless outbounds: ${skipped}" >&2
fi

# the vless:// parser in vless.sh splits on ':' and cannot handle IPv6 hosts
ipv6=$(jq -r '
    [ .[] | .outbounds[]?
      | select(.protocol == "vless")
      | .settings.vnext[0].address // empty
      | select(test(":")) ]
    | unique | join(", ")' <<<"${input}")
if [[ -n "${ipv6}" ]]; then
    echo "sub-adapter: skipped IPv6 servers (unsupported by parser): ${ipv6}" >&2
fi

jq -r '
    [ .[]
      | (.remarks // "") as $rem
      | .outbounds[]?
      | select(.protocol == "vless")
      | (.settings.vnext[0] // {}) as $v
      | ($v.users[0] // {}) as $u
      | (.streamSettings // {}) as $s
      | select($v.address != null and ($u.id // "") != "")
      | select($v.address | test(":") | not)
      | ( ($s[($s.network // "") + "Settings"] // {})
          + ($s.realitySettings // {})
          + ($s.tlsSettings // {}) ) as $x
      | ( { encryption: ($u.encryption // null),
            type: ($s.network // null),
            security: ($s.security // null),
            sni: ($x.serverName // null),
            pbk: ($x.publicKey // null),
            sid: ($x.shortId // null),
            fp: ($x.fingerprint // null),
            flow: ($u.flow // null),
            path: ($x.path // null),
            mode: ($x.mode // null),
            host: ($x.host // null),
            alpn: (($x.alpn // []) | join(",")) }
          | with_entries(select(.value != null and .value != ""))
          | to_entries | map("\(.key)=\(.value | @uri)") | join("&") ) as $qs
      | ( $rem
          | gsub("#"; "%23") | gsub("@"; "%40") | gsub("\\?"; "%3F") | gsub(":"; "%3A") ) as $frag
      | { key: "\($v.address):\($v.port)",
          remark: $rem,
          line: "vless://\($u.id)@\($v.address):\($v.port)?\($qs)#\($frag)" }
    ]
    | group_by(.key)
    | map(sort_by(if (.remark | test("Авто")) then 1 else 0 end) | .[0].line)
    | .[]' <<<"${input}"
