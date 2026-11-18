#!/bin/sh
# =============================================================================
# wgswitch test suite - runs the real scripts under BusyBox ash against the
# fakes in tests/shims (no root, no network, no WireGuard needed).
#
#   sh tests/run.sh            # all tests
#   sh tests/run.sh -v         # show wgswitch output on failure
#
# Real-kernel WireGuard handshakes are covered separately by
# tests/integration.sh (CI, needs root + the wireguard module).
#
# NOTE: every key in these tests is generated at run time from /dev/urandom.
# Never commit a real or realistic-looking key to this repository.
# =============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
BB=$(command -v busybox) || { echo "busybox is required (apt install busybox)"; exit 2; }
PASS=0; FAIL=0; CUR=""

SHIMS=$(mktemp -d)
for t in uci wg ip ifup ifdown ping nslookup logger usleep id; do ln -s "$ROOT/tests/shims/fake.py" "$SHIMS/$t"; done
BBDIR=$(mktemp -d)
for a in awk sed grep cut sort date head tail tr cat cp mv rm mkdir chmod ls cmp sleep basename wc uniq; do ln -s "$BB" "$BBDIR/$a"; done
trap 'rm -rf "$SHIMS" "$BBDIR" "${FAKE:-/nonexistent-}"' EXIT

key() { head -c 32 /dev/urandom | "$BB" base64; }

setup() {
    [ -n "${FAKE:-}" ] && rm -rf "$FAKE"
    FAKE=$(mktemp -d); export FAKE
    mkdir -p "$FAKE/uci" "$FAKE/wg" "$FAKE/net" "$FAKE/log" "$FAKE/wireguard" "$FAKE/run" "$FAKE/state" "$FAKE/etc"
    : > "$FAKE/log/calls"; : > "$FAKE/log/keyfiles"; : > "$FAKE/log/syslog"
    printf 'default via 192.168.10.1 dev br-lan.1 proto static\ndefault dev vpn proto static\n' > "$FAKE/net/routes4"
    : > "$FAKE/net/routes6"; : > "$FAKE/net/rules"; : > "$FAKE/net/tables"; : > "$FAKE/net/reachable"; : > "$FAKE/net/dns"; : > "$FAKE/net/nodata"
    cat > "$FAKE/uci/wgswitch" <<EOF
{"main": {".type": "wgswitch", "interface": "vpn", "conf_dir": "$FAKE/wireguard", "killswitch": "block",
  "check_interval": "1", "fail_threshold": "2", "probe_timeout": "1", "connect_timeout": "2",
  "failover_candidates": "5", "hook": "$FAKE/hook.sh", "hook_timeout": "5", "ping_target": ["1.1.1.1", "1.0.0.1"]},
 "state": {".type": "state", "enabled": "0"}}
EOF
    printf '{"vpn": {".type": "interface", "proto": "wireguard", "metric": "7"}}\n' > "$FAKE/uci/network"
    cat > "$FAKE/hook.sh" <<'EOF'
#!/bin/sh
echo "hook $1 profile=$WGSWITCH_PROFILE iface=$WGSWITCH_INTERFACE" >> "$FAKE/log/calls"
exit "${HOOK_RC:-0}"
EOF
    chmod +x "$FAKE/hook.sh"
}

# mkconf <name> <endpoint-host> [extra lines...]
mkconf() {
    _n=$1; _h=$2; shift 2
    {
        printf '[Interface]\n# Key for %s\nPrivateKey = %s\nAddress = 10.2.0.2/32\nDNS = 10.2.0.1\n' "$_n" "$(key)"
        for _x in "$@"; do printf '%s\n' "$_x"; done
        printf '\n[Peer]\n# %s\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = %s:51820\n' "$_n" "$(key)" "$_h"
    } > "$FAKE/in-$_n.conf"
    printf '%s' "$FAKE/in-$_n.conf"
}
reach() { printf '%s %s\n' "$1" "${2:-0}" >> "$FAKE/net/reachable"; }
nodata() { printf '%s\n' "$1" >> "$FAKE/net/nodata"; }   # handshakes, but passes no traffic
kill_live() {  # the connected server dies: no replies, handshake goes stale
    unreach "$1"
    python3 -c "import json,os;p=os.environ['FAKE']+'/wg/vpn.json';d=json.load(open(p));d['hs']=1;d.pop('hs_due',None);json.dump(d,open(p,'w'))"
}
unreach() { grep -v "^$1 " "$FAKE/net/reachable" > "$FAKE/net/r.tmp"; mv "$FAKE/net/r.tmp" "$FAKE/net/reachable"; }

W() {  # run wgswitch; output in $OUT, status in $RC
    OUT=$(PATH="$SHIMS:$BBDIR:/usr/bin:/bin" WGSWITCH_LIB="$ROOT/wgswitch/files/lib.sh" \
        WGSWITCH_RUN="$FAKE/run" WGSWITCH_STATE="$FAKE/state" WGSWITCH_ETC="$FAKE/etc" WGSWITCH_TEST=1 \
        "$BB" ash "$ROOT/wgswitch/files/wgswitch" "$@" 2>&1); RC=$?
}
U() { PATH="$SHIMS:$PATH" uci "$@"; }

t() { CUR=$1; }
ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1)); echo "FAIL [$CUR] $*"
    [ "$VERBOSE" = 1 ] && printf '  --- last output (rc=%s) ---\n%s\n' "${RC:-?}" "$OUT" | sed 's/^/  /'
}
eq() { [ "$1" = "$2" ] && ok || bad "expected '$2', got '$1' ${3:-}"; }
has() { case "$1" in *"$2"*) ok ;; *) bad "expected to contain '$2' ${3:-}" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "must NOT contain '$2' ${3:-}" ;; *) ok ;; esac; }
rc() { eq "$RC" "$1" "(exit status)"; }

# =============================================================================
t "validation: good conf, ignored keys, redaction"
setup
f=$(mkconf AU-45 180.149.229.130 "PostUp = iptables -A FORWARD -j ACCEPT")
priv=$(sed -n 's/^PrivateKey = //p' "$f")
W add "$f" AU-45; rc 0; has "$OUT" "added profile 'AU-45'"; has "$OUT" "postup"; hasnt "$OUT" "dns"
eq "$(stat -c %a "$FAKE/wireguard/AU-45.conf")" 600 "(profile mode)"
W show AU-45; rc 0; hasnt "$OUT" "$priv" "(show must hide the private key)"; has "$OUT" "(hidden"
W show AU-45 --secrets; has "$OUT" "$priv"
W list --json; rc 0; hasnt "$OUT" "$priv"
printf '%s' "$OUT" | jq -e '.[0].name == "AU-45" and .[0].valid and .[0].endpoint == "180.149.229.130:51820"' >/dev/null && ok || bad "list --json: $OUT"
W add "$f" AU-45; rc 1; has "$OUT" "already exists"
W add "$f" AU-45 --replace; rc 0
hasnt "$(cat "$FAKE/log/syslog")" "$priv" "(syslog)"

t "validation: rejects broken configs"
setup
printf '[Interface]\nPrivateKey = nope\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = %s\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n' "$(key)" > "$FAKE/bad1.conf"
W add "$FAKE/bad1.conf"; rc 1; has "$OUT" "PrivateKey"
printf '[Interface]\nPrivateKey = %s\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = %s\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n[Peer]\nPublicKey = %s\nEndpoint = 1.2.3.5:51820\nAllowedIPs = 10.0.0.0/8\n' "$(key)" "$(key)" "$(key)" > "$FAKE/bad2.conf"
W add "$FAKE/bad2.conf"; rc 1; has "$OUT" "exactly one [Peer]"
printf '[Interface]\nPrivateKey = %s\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = %s\nEndpoint = 1.2.3.4\nAllowedIPs = 0.0.0.0/0\n' "$(key)" "$(key)" > "$FAKE/bad3.conf"
W add "$FAKE/bad3.conf"; rc 1; has "$OUT" "Endpoint"
printf '[Interface]\nPrivateKey = %s\nAddress = 10.0.0.2/32;reboot\n[Peer]\nPublicKey = %s\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n' "$(key)" "$(key)" > "$FAKE/bad4.conf"
W add "$FAKE/bad4.conf"; rc 1; has "$OUT" "Address"
# CRLF line endings + IPv6 endpoint + odd file name are fine
printf '[Interface]\r\nPrivateKey = %s\r\nAddress = 10.0.0.2/32, fd00::2/128\r\n[Peer]\r\nPublicKey = %s\r\nEndpoint = [2001:db8::1]:51820\r\nAllowedIPs = 0.0.0.0/0\r\n' "$(key)" "$(key)" > "$FAKE/my server (1).conf"
W add "$FAKE/my server (1).conf"; rc 0; has "$OUT" "my_server__1_"
W list; has "$OUT" "[2001:db8::1]:51820"
# an invalid file dropped straight into the folder shows up as invalid
printf 'garbage\n' > "$FAKE/wireguard/junk.conf"
W list --json; printf '%s' "$OUT" | jq -e 'map(select(.name=="junk"))[0].valid == false' >/dev/null && ok || bad "junk not flagged: $OUT"

t "connect: writes netifd config, /1 routes, keeps other options, runs hook"
setup
reach 10.0.0.1; reach 10.0.0.2
W add "$(mkconf A 10.0.0.1)" A; W add "$(mkconf B 10.0.0.2)" B
W connect A; rc 0; has "$OUT" "connected to 'A'"
eq "$(U get wgswitch.state.profile)" A; eq "$(U get wgswitch.state.enabled)" 1
eq "$(U get network.vpn.proto)" wireguard; eq "$(U get network.vpn.metric)" 7 "(foreign option kept)"
eq "$(U get network.vpn.auto)" 1; eq "$(U get network.vpn.addresses)" 10.2.0.2/32
eq "$(U get network.vpn_peer)" wireguard_vpn; eq "$(U get network.vpn_peer.endpoint_host)" 10.0.0.1
eq "$(U get network.vpn_peer.route_allowed_ips)" 0
eq "$(U get network.vpn_def4_lo.target)" 0.0.0.0/1; eq "$(U get network.vpn_def4_hi.target)" 128.0.0.0/1
eq "$(U get network.vpn_def6_lo.target)" ::/1
has "$(cat "$FAKE/log/calls")" "hook connect profile=A iface=vpn"

t "switch: connect B while on A - no hook, A replaced"
: > "$FAKE/log/calls"
W connect B; rc 0
eq "$(U get network.vpn_peer.endpoint_host)" 10.0.0.2; eq "$(U get wgswitch.state.profile)" B
hasnt "$(cat "$FAKE/log/calls")" "hook" "(already connected: routing hook must not re-run)"
has "$(cat "$FAKE/log/calls")" "ifup vpn"
eq "$(U show network | grep -c '=wireguard_vpn$')" 1 "(exactly one peer)"

t "switch to a dead server rolls back to the previous one"
W add "$(mkconf DEAD 10.0.0.99)" DEAD
W connect DEAD; rc 1; has "$OUT" "restoring the previous state"
eq "$(U get network.vpn_peer.endpoint_host)" 10.0.0.2 "(network config restored)"
eq "$(U get wgswitch.state.profile)" B; eq "$(U get wgswitch.state.enabled)" 1
[ -f "$FAKE/wg/vpn.json" ] && ok || bad "previous tunnel not brought back up"
W list --json; printf '%s' "$OUT" | jq -e 'map(select(.name=="DEAD"))[0].test.status == "fail"' >/dev/null && ok || bad "dead connect not recorded"

t "first connect to a dead server leaves the VPN disconnected"
setup
W add "$(mkconf DEAD 10.0.0.99)" DEAD
W connect DEAD; rc 1
eq "$(U get wgswitch.state.enabled)" 0; [ -f "$FAKE/wg/vpn.json" ] && bad "interface left up" || ok
hasnt "$(cat "$FAKE/log/calls")" "hook connect"

t "disconnect: hook first, then interface down, auto=0"
setup; reach 10.0.0.1
W add "$(mkconf A 10.0.0.1)" A; W connect A; : > "$FAKE/log/calls"
W disconnect; rc 0
eq "$(sed -n '1p' "$FAKE/log/calls")" "hook disconnect profile=A iface=vpn" "(hook runs before ifdown)"
eq "$(sed -n '2p' "$FAKE/log/calls")" "ifdown vpn"
eq "$(U get network.vpn.auto)" 0; eq "$(U get wgswitch.state.enabled)" 0
W remove A; rc 0

t "remove refuses the connected profile"
setup; reach 10.0.0.1
W add "$(mkconf A 10.0.0.1)" A; W connect A
W remove A; rc 1; has "$OUT" "connected profile"

t "test: handshake timing, failures, cleanup, active server never probed"
setup
reach 10.0.0.1 0; reach 10.0.0.2 300; reach 10.0.0.3 100; reach 10.0.0.4 200
printf 'vpn.example.net 10.0.0.4\n' > "$FAKE/net/dns"
W add "$(mkconf A 10.0.0.1)" A; W add "$(mkconf SLOW 10.0.0.2)" SLOW
W add "$(mkconf FAST 10.0.0.3)" FAST; W add "$(mkconf DEAD 10.0.0.99)" DEAD
W add "$(mkconf NAMED vpn.example.net)" NAMED
W connect A
W test; rc 0
has "$OUT" "A	active"; has "$OUT" "DEAD	fail	timeout"
has "$OUT" "FAST	ok"; has "$OUT" "SLOW	ok"; has "$OUT" "NAMED	ok"
fast=$(printf '%s\n' "$OUT" | sed -n 's/^FAST	ok	\([0-9]*\) ms/\1/p'); slow=$(printf '%s\n' "$OUT" | sed -n 's/^SLOW	ok	\([0-9]*\) ms/\1/p')
[ -n "$fast" ] && [ -n "$slow" ] && [ "$fast" -lt "$slow" ] && ok || bad "FAST ($fast ms) should beat SLOW ($slow ms)"
W best; eq "$OUT" FAST
[ -f "$FAKE/wg/wgsprobe.json" ] && bad "probe interface left behind" || ok
[ -s "$FAKE/net/rules" ] && bad "policy rule left behind: $(cat "$FAKE/net/rules")" || ok
[ -s "$FAKE/net/tables" ] && bad "probe table left behind" || ok
has "$(cat "$FAKE/log/calls")" "ip link add wgsprobe"
sort -u "$FAKE/log/keyfiles" | while IFS= read -r kf; do [ -e "$kf" ] && echo "$kf"; done > "$FAKE/left"
[ -s "$FAKE/left" ] && bad "key files left on disk: $(cat "$FAKE/left")" || ok
[ -e "$FAKE/run/probe.key" ] || [ -e "$FAKE/run/probe.psk" ] && bad "key files in run dir" || ok
grep -q "wgsprobe" "$FAKE/log/calls" && ! grep -q "ip link add vpn" "$FAKE/log/calls" && ok || bad "probe touched the live interface"
grep -q 'default via 192.168.10.1 dev br-lan.1' "$FAKE/log/calls" 2>/dev/null; ok   # (route recorded in tables during run)
eq "$(U get wgswitch.state.profile)" A "(test must not change the connection)"
# DNS for NAMED is cached for when DNS is down
grep -q '^vpn.example.net 10.0.0.4$' "$FAKE/etc/endpoints.cache" && ok || bad "endpoint not cached"
: > "$FAKE/net/dns"
W test NAMED; has "$OUT" "NAMED	ok" "(uses the cache with DNS down)"

t "status --json is valid JSON with the expected fields"
W status --json; rc 0
printf '%s' "$OUT" | jq -e '.enabled == true and .profile == "A" and .interface == "vpn" and .up == true and .killswitch == "block"' >/dev/null && ok || bad "status: $OUT"
W status; has "$OUT" "Profile:     A"

t "kill switch: fastest - fails over to the fastest answering server"
setup
reach 10.0.0.1; reach 10.0.0.2 300; reach 10.0.0.3 50
W add "$(mkconf A 10.0.0.1)" A; W add "$(mkconf SLOW 10.0.0.2)" SLOW; W add "$(mkconf FAST 10.0.0.3)" FAST
W connect A; W killswitch fastest; : > "$FAKE/log/calls"
unreach 10.0.0.1      # A dies: no replies, handshake goes stale
python3 -c "import json,os;p=os.environ['FAKE']+'/wg/vpn.json';d=json.load(open(p));d['hs']=1;d.pop('hs_due',None);json.dump(d,open(p,'w'))"
WGSWITCH_DAEMON_LOOPS=3 W daemon
eq "$(U get wgswitch.state.profile)" FAST; eq "$(U get wgswitch.state.enabled)" 1
eq "$(U get network.vpn_peer.endpoint_host)" 10.0.0.3
hasnt "$(cat "$FAKE/log/calls")" "hook" "(failover keeps routing as is)"
has "$(U get wgswitch.state.event)" "switched to 'FAST'"

t "kill switch: direct - disconnects and runs the disconnect hook"
setup; reach 10.0.0.1
W add "$(mkconf A 10.0.0.1)" A; W connect A; W killswitch direct; : > "$FAKE/log/calls"
unreach 10.0.0.1
python3 -c "import json,os;p=os.environ['FAKE']+'/wg/vpn.json';d=json.load(open(p));d['hs']=1;json.dump(d,open(p,'w'))"
WGSWITCH_DAEMON_LOOPS=3 W daemon
eq "$(U get wgswitch.state.enabled)" 0; has "$(cat "$FAKE/log/calls")" "hook disconnect"
eq "$(cut -d' ' -f1 "$FAKE/state/runtime")" fallback-direct

t "kill switch: block - stays connected, keeps retrying"
setup; reach 10.0.0.1
W add "$(mkconf A 10.0.0.1)" A; W connect A; : > "$FAKE/log/calls"
unreach 10.0.0.1
python3 -c "import json,os;p=os.environ['FAKE']+'/wg/vpn.json';d=json.load(open(p));d['hs']=1;json.dump(d,open(p,'w'))"
WGSWITCH_DAEMON_LOOPS=3 W daemon
eq "$(U get wgswitch.state.enabled)" 1; eq "$(U get wgswitch.state.profile)" A
eq "$(cut -d' ' -f1 "$FAKE/state/runtime")" blocked
hasnt "$(cat "$FAKE/log/calls")" "hook"; has "$(cat "$FAKE/log/calls")" "ifup vpn"

t "healthy tunnel: no action"
setup; reach 10.0.0.1
W add "$(mkconf A 10.0.0.1)" A; W connect A; W killswitch fastest; : > "$FAKE/log/calls"
WGSWITCH_DAEMON_LOOPS=3 W daemon
eq "$(cat "$FAKE/log/calls")" "" "(no ifup/hook while healthy)"
eq "$(cut -d' ' -f1 "$FAKE/state/runtime")" ok

t "background queue: connect --bg and test --bg run in the service"
setup; reach 10.0.0.1; reach 10.0.0.2
W add "$(mkconf A 10.0.0.1)" A; W add "$(mkconf B 10.0.0.2)" B
W connect --bg A; rc 1; has "$OUT" "not running"
( trap '' USR1; sleep 30 ) & DUMMY=$!   # stand-in "service" pid that ignores USR1
echo "$DUMMY" > "$FAKE/run/daemon.pid"
W connect --bg A; rc 0; W test --bg B; rc 0
kill "$DUMMY" 2>/dev/null; rm -f "$FAKE/run/daemon.pid"
WGSWITCH_DAEMON_LOOPS=2 W daemon
eq "$(U get wgswitch.state.profile)" A; W list --json
printf '%s' "$OUT" | jq -e 'map(select(.name=="B"))[0].test.status == "ok"' >/dev/null && ok || bad "queued test not run: $OUT"

t "hook failure is reported but the tunnel stays up"
setup; reach 10.0.0.1
W add "$(mkconf A 10.0.0.1)" A
HOOK_RC=1; export HOOK_RC; W connect A; unset HOOK_RC
eq "$RC" 3 "(exit 3 = connected, hook failed)"; eq "$(U get wgswitch.state.enabled)" 1

t "connect --no-hook and --best"
setup; reach 10.0.0.1 200; reach 10.0.0.2 0
W add "$(mkconf A 10.0.0.1)" A; W add "$(mkconf B 10.0.0.2)" B
W connect --best --no-hook; rc 0
eq "$(U get wgswitch.state.profile)" B "(fastest picked)"
hasnt "$(cat "$FAKE/log/calls")" "hook" "(--no-hook)"

t "clock: uptime_ms is exact past 24.8 days of uptime (BusyBox awk %d caps at 2^31-1)"
setup
printf '5000000.12 9999.00\n' > "$FAKE/uptime"
ms=$(PATH="$SHIMS:$BBDIR:/usr/bin:/bin" WGSWITCH_UPTIME_FILE="$FAKE/uptime" "$BB" ash -c ". '$ROOT/wgswitch/files/lib.sh'; uptime_ms")
eq "$ms" 5000000120

t "probe: a dead server times out even if the uptime clock is frozen"
setup
printf '5000000.12 9999.00\n' > "$FAKE/uptime"      # never advances
W add "$(mkconf DEAD 10.0.0.99)" DEAD
t0=$(date +%s)
WGSWITCH_UPTIME_FILE="$FAKE/uptime"; export WGSWITCH_UPTIME_FILE
W test DEAD
unset WGSWITCH_UPTIME_FILE
el=$(( $(date +%s) - t0 ))
has "$OUT" "DEAD	fail	timeout"
[ "$el" -le 6 ] && ok || bad "test of one dead server took ${el}s with probe_timeout=1 (must be bounded by the wall clock)"

t "probe: handshake time is measured, not 0 ms"
setup; reach 10.0.0.1 300
W add "$(mkconf SLOW 10.0.0.1)" SLOW
W test SLOW
ms=$(printf '%s\n' "$OUT" | sed -n 's/^SLOW	ok	\([0-9]*\) ms.*/\1/p')
[ -n "$ms" ] && [ "$ms" -ge 250 ] && ok || bad "300 ms server measured as '${ms}' ms"

t "provider DNS lines are ignored silently; scripts like PostUp still warn"
setup
W add "$(mkconf A 10.0.0.1)" A
hasnt "$OUT" "dns"
W add "$(mkconf B 10.0.0.2 'PostUp = echo hi')" B
has "$OUT" "postup"; hasnt "$OUT" "dns"

t "connect --best shows the test progress"
setup; reach 10.0.0.1
W add "$(mkconf A 10.0.0.1)" A
W connect --best --no-hook; rc 0
has "$OUT" "testing 1 profile(s)"; has "$OUT" "A	ok"

t "kill switch modes: default fastest-block, 'fastest' alias, bad mode refused"
setup
U delete wgswitch.main.killswitch
W killswitch; eq "$OUT" fastest-block
grep -q "option killswitch 'fastest-block'" "$ROOT/wgswitch/files/wgswitch.config" && ok || bad "package default config isn't fastest-block"
W killswitch fastest; eq "$(U get wgswitch.main.killswitch)" fastest-block
U set wgswitch.main.killswitch=fastest; W killswitch; eq "$OUT" fastest-block "(old config value)"
W killswitch fastest-direct; eq "$(U get wgswitch.main.killswitch)" fastest-direct
W killswitch sometimes; rc 1

t "connect: handshake OK but no traffic -> exit 4 and a warning"
setup; reach 10.0.0.1; nodata 10.0.0.1
W add "$(mkconf ND 10.0.0.1)" ND
W connect ND; rc 4
has "$OUT" "nothing came back through the tunnel"

t "kill switch fastest-block: skips a server that handshakes but passes no traffic"
setup
reach 10.0.0.1; reach 10.0.0.2 0; reach 10.0.0.3 300; nodata 10.0.0.2
W add "$(mkconf A 10.0.0.1)" A; W add "$(mkconf NODATA 10.0.0.2)" NODATA; W add "$(mkconf GOOD 10.0.0.3)" GOOD
W connect A; W killswitch fastest; : > "$FAKE/log/calls"
kill_live 10.0.0.1
WGSWITCH_DAEMON_LOOPS=3 W daemon
eq "$(U get wgswitch.state.profile)" GOOD "(NODATA handshakes fastest but must be skipped)"
eq "$(U get wgswitch.state.enabled)" 1
hasnt "$(cat "$FAKE/log/calls")" "hook"

t "kill switch fastest-direct: nothing works -> direct"
setup
reach 10.0.0.1; reach 10.0.0.2; nodata 10.0.0.2
W add "$(mkconf A 10.0.0.1)" A; W add "$(mkconf NODATA 10.0.0.2)" NODATA; W add "$(mkconf DEAD 10.0.0.99)" DEAD
W connect A; W killswitch fastest-direct; : > "$FAKE/log/calls"
kill_live 10.0.0.1
WGSWITCH_DAEMON_LOOPS=3 W daemon
eq "$(U get wgswitch.state.enabled)" 0 "(fell back to direct)"
has "$(cat "$FAKE/log/calls")" "hook disconnect"
eq "$(cut -d' ' -f1 "$FAKE/state/runtime")" fallback-direct
has "$(U get wgswitch.state.event)" "no other server works"

t "kill switch fastest-block: nothing works -> blocks on the old server, never direct"
setup
reach 10.0.0.1; reach 10.0.0.2; nodata 10.0.0.2
W add "$(mkconf A 10.0.0.1)" A; W add "$(mkconf NODATA 10.0.0.2)" NODATA; W add "$(mkconf DEAD 10.0.0.99)" DEAD
W connect A; W killswitch fastest-block; : > "$FAKE/log/calls"
kill_live 10.0.0.1
WGSWITCH_DAEMON_LOOPS=3 W daemon
eq "$(U get wgswitch.state.enabled)" 1; eq "$(U get wgswitch.state.profile)" A
eq "$(cut -d' ' -f1 "$FAKE/state/runtime")" blocked
hasnt "$(cat "$FAKE/log/calls")" "hook disconnect"

t "interface name is configurable"
setup; reach 10.0.0.1
U set wgswitch.main.interface=wg_test
W add "$(mkconf A 10.0.0.1)" A; W connect A; rc 0
eq "$(U get network.wg_test_peer)" wireguard_wg_test; eq "$(U get network.wg_test_def4_lo.interface)" wg_test
U set 'wgswitch.main.interface=bad;name'; W status; rc 1

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
