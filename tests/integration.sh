#!/bin/sh
# =============================================================================
# Integration test: the real probe (`wgswitch test`) against real kernel
# WireGuard servers, in network namespaces. Needs root, iproute2 (with
# netns), wireguard-tools, busybox and the wireguard kernel module.
# Runs in CI (GitHub Actions runners have all of these); never on a router.
#
#   sudo sh tests/integration.sh
#
# Topology:
#
#   [cli] c0 10.77.0.2 ---- 10.77.0.1 r0 [rtr] r1..r4 ---- s1..s4 [srv1..srv4]
#     default via 10.77.0.1                       10.77.k.1   10.77.k.2
#     "vpn": a dummy device with 0.0.0.0/1 + 128.0.0.0/1 - a dead live
#     tunnel. If the probe's packets followed those routes they would be
#     dropped, so every "ok" below proves they went via the underlay.
#
#   srv1: WireGuard server, knows our key           -> ok, fast
#   srv2: same, but 300 ms extra delay (netem)       -> ok, slower than srv1
#   srv3: nothing listening                          -> fail
#   srv4: WireGuard server that doesn't know our key -> fail (rejected key)
#
# All keys are generated here, at run time, and deleted afterwards.
# =============================================================================
# shellcheck disable=SC2016,SC2317  # checks are eval'd strings; cleanup runs via trap
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
for c in ip wg busybox jq python3; do command -v "$c" >/dev/null || { echo "missing: $c"; exit 2; }; done
modprobe wireguard 2>/dev/null || true

W=$(mktemp -d)
cleanup() {
    for n in cli rtr srv1 srv2 srv3 srv4; do ip netns del "$n" 2>/dev/null || true; done
    rm -rf "$W"
}
trap cleanup EXIT

nsx() { ip netns exec "$@"; }
for n in cli rtr srv1 srv2 srv3 srv4; do ip netns add "$n"; nsx "$n" ip link set lo up; done
nsx rtr sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'

ip link add c0 netns cli type veth peer name r0 netns rtr
nsx cli ip addr add 10.77.0.2/24 dev c0; nsx cli ip link set c0 up
nsx rtr ip addr add 10.77.0.1/24 dev r0; nsx rtr ip link set r0 up
nsx cli ip route add default via 10.77.0.1
nsx cli ip link add vpn type dummy; nsx cli ip link set vpn up
nsx cli ip route add 0.0.0.0/1 dev vpn; nsx cli ip route add 128.0.0.0/1 dev vpn

for k in 1 2 3 4; do
    ip link add "r$k" netns rtr type veth peer name "s$k" netns "srv$k"
    nsx rtr ip addr add "10.77.$k.1/24" dev "r$k"; nsx rtr ip link set "r$k" up
    nsx "srv$k" ip addr add "10.77.$k.2/24" dev "s$k"; nsx "srv$k" ip link set "s$k" up
    nsx "srv$k" ip route add default via "10.77.$k.1"
done
nsx srv2 tc qdisc add dev s2 root netem delay 300ms

umask 077
wg genkey > "$W/client.key"; CLIENT_PUB=$(wg pubkey < "$W/client.key")
wg genkey > "$W/other.key"; OTHER_PUB=$(wg pubkey < "$W/other.key")
for k in 1 2 4; do
    wg genkey > "$W/srv$k.key"; wg pubkey < "$W/srv$k.key" > "$W/srv$k.pub"
    nsx "srv$k" ip link add wg0 type wireguard
    peer=$CLIENT_PUB; [ "$k" = 4 ] && peer=$OTHER_PUB
    nsx "srv$k" wg set wg0 private-key "$W/srv$k.key" listen-port 51820 peer "$peer" allowed-ips 10.2.0.2/32
    nsx "srv$k" ip link set wg0 up
done
wg genkey | wg pubkey > "$W/srv3.pub"   # nobody behind it

mkdir -p "$W/wireguard" "$W/run" "$W/state" "$W/etc" "$W/uci" "$W/log" "$W/shims" "$W/bb"
for k in 1 2 3 4; do
    printf '[Interface]\nPrivateKey = %s\nAddress = 10.2.0.2/32\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0\nEndpoint = 10.77.%s.2:51820\n' \
        "$(cat "$W/client.key")" "$(cat "$W/srv$k.pub")" "$k" > "$W/wireguard/srv$k.conf"
done
chmod 600 "$W"/wireguard/*.conf
cat > "$W/uci/wgswitch" <<EOF
{"main": {".type": "wgswitch", "interface": "vpn", "conf_dir": "$W/wireguard", "probe_timeout": "3"},
 "state": {".type": "state", "enabled": "0"}}
EOF
# only uci/logger/usleep are faked; ip, wg and the kernel are real
for t in uci logger usleep; do ln -s "$ROOT/tests/shims/fake.py" "$W/shims/$t"; done
for a in awk sed grep cut sort date head tail tr cat cp mv rm mkdir chmod ls cmp sleep basename wc; do ln -s "$(command -v busybox)" "$W/bb/$a"; done

OUT=$(nsx cli env FAKE="$W" PATH="$W/shims:$W/bb:$PATH" WGSWITCH_LIB="$ROOT/wgswitch/files/lib.sh" \
    WGSWITCH_RUN="$W/run" WGSWITCH_STATE="$W/state" WGSWITCH_ETC="$W/etc" \
    busybox ash "$ROOT/wgswitch/files/wgswitch" test 2>&1) || true
printf '%s\n' "$OUT"

fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }
ms() { printf '%s\n' "$OUT" | sed -n "s/^$1	ok	\([0-9]*\) ms.*/\1/p"; }
check "srv1 answers"                    '[ -n "$(ms srv1)" ]'
check "srv2 answers"                    '[ -n "$(ms srv2)" ]'
check "srv2 (300 ms delay) is slower"   '[ -n "$(ms srv1)" ] && [ -n "$(ms srv2)" ] && [ "$(ms srv2)" -gt "$(ms srv1)" ] && [ "$(ms srv2)" -ge 250 ]'
check "srv3 (nothing listening) fails"  'printf "%s\n" "$OUT" | grep -q "^srv3	fail"'
check "srv4 (unknown key) fails"        'printf "%s\n" "$OUT" | grep -q "^srv4	fail"'
check "probe interface removed"         '! nsx cli ip link show wgsprobe >/dev/null 2>&1'
check "policy rules removed"            '! nsx cli ip rule show | grep -q 0x5157'
check "probe table flushed"             '[ -z "$(nsx cli ip route show table 5157)" ]'
check "no key files left"               '[ -z "$(ls "$W/run" | grep -i -e key -e psk)" ]'
check "srv1 saw our handshake"          '[ "$(nsx srv1 wg show wg0 latest-handshakes | cut -f2)" != 0 ]'
exit "$fail"
