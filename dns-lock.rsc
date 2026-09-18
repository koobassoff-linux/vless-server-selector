# dns-lock.rsc — конец DNS-анархии (импортировать один раз, повторный импорт безопасен)
# Истина = DoH-ответы роутера; клиенты резолвят только через роутер.
# Откат точечный: все созданные правила имеют comment="dns-lock",
# откат полный: /system restore boot-file=pre-dnslock-20260918
# ВНИМАНИЕ: импорт через не-tty ssh-stdin не работает (роутер теряет контексты
# и молча съедает комментарии/переносы) — только интерактивный терминал/WinBox,
# либо full-path команды по одной.

# 1) известные DoH-серверы (для блокировки обходов)
/ip firewall address-list
remove [find comment="dns-lock"]
add list=doh-servers address=1.1.1.1 comment="dns-lock"
add list=doh-servers address=1.0.0.1 comment="dns-lock"
add list=doh-servers address=8.8.8.8 comment="dns-lock"
add list=doh-servers address=8.8.4.4 comment="dns-lock"
add list=doh-servers address=9.9.9.9 comment="dns-lock"
add list=doh-servers address=94.140.14.14 comment="dns-lock"
add list=doh-servers address=94.140.15.15 comment="dns-lock"

# 2) любой DNS с LAN (даже с вписанным 8.8.8.8) приходит к роутеру
/ip firewall nat
remove [find comment="dns-lock"]
add chain=dstnat src-address=192.168.88.0/24 protocol=udp dst-port=53 \
    action=dst-nat to-addresses=192.168.88.1 to-ports=53 comment="dns-lock"
add chain=dstnat src-address=192.168.88.0/24 protocol=tcp dst-port=53 \
    action=dst-nat to-addresses=192.168.88.1 to-ports=53 comment="dns-lock"

# 3) обходы: DoT reject, DoH (включая QUIC) drop; в начало цепочки (place-before=0)
# NOTE: src-address-list — это IP-адрес-лист; LAN у нас interface-list, нужен
# in-interface-list, иначе правило не матчится никогда.
/ip firewall filter
remove [find comment="dns-lock"]
add chain=forward in-interface-list=LAN protocol=tcp dst-port=853 action=reject \
    place-before=0 comment="dns-lock"
add chain=forward in-interface-list=LAN protocol=tcp dst-address-list=doh-servers \
    dst-port=443 action=drop place-before=0 comment="dns-lock"
add chain=forward in-interface-list=LAN protocol=udp dst-address-list=doh-servers \
    dst-port=443 action=drop place-before=0 comment="dns-lock"

# 4) резолвер: DoH cloudflare, свежие кэши
# NOTE: списочный use-doh-server (через запятую) CLI принимает, но резолвинг
# молча умирает — проверено на 7.24.2; только один сервер.
/ip dns static
remove [find comment="dns-lock" || name="dns.google"]
add name=dns.google type=A address=8.8.8.8 comment="dns-lock"
/ip dns
set use-doh-server=https://cloudflare-dns.com/dns-query
set verify-doh-cert=yes
set cache-max-ttl=1d
set address-list-extra-time=300s

:put "dns-lock: applied"
