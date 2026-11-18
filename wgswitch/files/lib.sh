# shellcheck shell=sh
# =============================================================================
# wgswitch library - sourced by /usr/sbin/wgswitch. POSIX sh (BusyBox ash).
#
# Conventions:
#   * No `local` (POSIX); function-private variables are prefixed with _.
#   * Secrets (PrivateKey/PresharedKey) never go to stdout/stderr/syslog.
#     They only ever exist in: the .conf file (0600), netifd's uci config
#     (where WireGuard keys always live on OpenWrt), and short-lived 0600
#     files under $WGS_RUN (tmpfs) that are removed straight after `wg set`.
#   * Every operation that changes live state holds $WGS_RUN/lock.
# =============================================================================

WGS_RUN="${WGSWITCH_RUN:-/var/run/wgswitch}"
WGS_STATE="${WGSWITCH_STATE:-/tmp/wgswitch}"
WGS_ETC="${WGSWITCH_ETC:-/etc/wgswitch}"
WGS_RESULTS="$WGS_STATE/results"
WGS_HEALTH="$WGS_STATE/health"
WGS_PROGRESS="$WGS_STATE/test.progress"
WGS_EPCACHE="$WGS_ETC/endpoints.cache"
TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
WGS_QUIET="${WGS_QUIET:-0}"
_log() {
    _l_lvl="$1"; shift
    logger -t wgswitch -p "daemon.$_l_lvl" -- "$*" 2>/dev/null || true
    [ "$WGS_QUIET" = 1 ] && return 0
    case "$_l_lvl" in
        err)     printf 'error: %s\n' "$*" >&2 ;;
        warning) printf 'warning: %s\n' "$*" >&2 ;;
        *)       printf '%s\n' "$*" >&2 ;;
    esac
}
log_info() { _log info "$@"; }
log_warn() { _log warning "$@"; }
log_err()  { _log err "$@"; }
die() { log_err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# config (uci: /etc/config/wgswitch)
# ---------------------------------------------------------------------------
cfg() {  # cfg <option> [default]  - from section 'main'
    _c_v=$(uci -q get "wgswitch.main.$1" 2>/dev/null)
    [ -n "$_c_v" ] && printf '%s' "$_c_v" || printf '%s' "${2:-}"
}
state_get() {  # runtime state that must survive reboot, section 'state'
    uci -q get "wgswitch.state.$1" 2>/dev/null || true
}
state_set() {  # state_set <opt> <value> ... ; commits once
    uci -q get wgswitch.state >/dev/null 2>&1 || uci set wgswitch.state=state
    while [ $# -ge 2 ]; do
        if [ -n "$2" ]; then uci set "wgswitch.state.$1=$2"; else uci -q delete "wgswitch.state.$1" 2>/dev/null || true; fi
        shift 2
    done
    uci commit wgswitch
}

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# shellcheck disable=SC2034  # several of these are used by /usr/sbin/wgswitch
load_config() {
    IFACE=$(cfg interface wg0)
    CONF_DIR=$(cfg conf_dir /etc/wireguard)
    KILLSWITCH=$(cfg killswitch fastest)
    FALLBACK=$(cfg fallback direct)
    ROUTE_MODE=$(cfg route_mode split)
    INTERVAL=$(cfg check_interval 15)
    FAIL_THRESHOLD=$(cfg fail_threshold 3)
    HS_MAX=$(cfg handshake_timeout 180)
    CONNECT_TIMEOUT=$(cfg connect_timeout 20)
    PROBE_TIMEOUT=$(cfg probe_timeout 7)
    FAILOVER_CANDIDATES=$(cfg failover_candidates 5)
    PING_TARGETS=$(cfg ping_target "1.1.1.1 1.0.0.1")
    HOOK=$(cfg hook "")
    HOOK_TIMEOUT=$(cfg hook_timeout 90)
    PROBE_IF=$(cfg probe_interface wgsprobe)
    FWMARK=$(cfg fwmark 0x5157)
    PROBE_TABLE=$(cfg probe_table 5157)
    PROBE_PRIO=$(cfg probe_rule_priority 5157)

    case "$IFACE" in
        ''|*[!A-Za-z0-9_]*) die "invalid interface name '$IFACE' (letters, digits, _ only)" ;;
    esac
    [ "${#IFACE}" -le 15 ] || die "interface name '$IFACE' is longer than 15 characters"
    case "$PROBE_IF" in ''|*[!A-Za-z0-9_]*) die "invalid probe_interface '$PROBE_IF'" ;; esac
    [ "$PROBE_IF" != "$IFACE" ] || die "probe_interface must differ from interface"
    case "$KILLSWITCH" in block|fastest|direct) ;; *) log_warn "unknown killswitch '$KILLSWITCH', using fastest"; KILLSWITCH=fastest ;; esac
    case "$FALLBACK" in direct|block) ;; *) log_warn "unknown fallback '$FALLBACK', using direct"; FALLBACK=direct ;; esac
    case "$ROUTE_MODE" in split|allowed_ips|none) ;; *) log_warn "unknown route_mode '$ROUTE_MODE', using split"; ROUTE_MODE='split' ;; esac
    for _v in INTERVAL FAIL_THRESHOLD HS_MAX CONNECT_TIMEOUT PROBE_TIMEOUT FAILOVER_CANDIDATES HOOK_TIMEOUT PROBE_TABLE PROBE_PRIO; do
        eval "_x=\$$_v"
        # shellcheck disable=SC2154
        is_uint "$_x" || die "option for $_v must be a whole number (got '$_x')"
    done
    [ "$INTERVAL" -ge 5 ] || [ -n "${WGSWITCH_TEST:-}" ] || INTERVAL=5
    [ "$FAIL_THRESHOLD" -ge 1 ] || FAIL_THRESHOLD=1
    mkdir -p "$WGS_RUN" "$WGS_STATE" 2>/dev/null
    chmod 700 "$WGS_RUN" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# locking: mkdir is atomic. Stale locks (dead pid) are reclaimed.
# ---------------------------------------------------------------------------
lock_try() {  # lock_try <name>
    _lk="$WGS_RUN/$1.lock"
    if mkdir "$_lk" 2>/dev/null; then echo $$ > "$_lk/pid"; return 0; fi
    _lp=$(cat "$_lk/pid" 2>/dev/null)
    if [ -n "$_lp" ] && ! kill -0 "$_lp" 2>/dev/null; then
        rm -rf "$_lk"
        mkdir "$_lk" 2>/dev/null && { echo $$ > "$_lk/pid"; return 0; }
    fi
    return 1
}
lock_wait() {  # lock_wait <name> <seconds>
    _lw_n=0
    while ! lock_try "$1"; do
        _lw_n=$((_lw_n + 1))
        [ "$_lw_n" -gt "$2" ] && return 1
        sleep 1
    done
    return 0
}
lock_release() { rm -rf "$WGS_RUN/$1.lock" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------
now() { date +%s; }
# Milliseconds since boot. NOT printf "%d": BusyBox awk caps %d at 2^31-1,
# which /proc/uptime*1000 passes after ~24.8 days - the clock then froze,
# every probe measured "0 ms" and a server that never answered hung the test
# forever. %.0f is exact for any realistic uptime.
uptime_ms() { awk '{ printf "%.0f", $1 * 1000 }' "${WGSWITCH_UPTIME_FILE:-/proc/uptime}"; }
# nap <microseconds>: sub-second where possible. OpenWrt 25.12's BusyBox has
# no usleep; its sleep accepts fractions when built with FLOAT_SLEEP.
nap() {
    sleep "$(awk -v u="$1" 'BEGIN { printf "%.3f", u / 1000000 }')" 2>/dev/null \
        || usleep "$1" 2>/dev/null || sleep 1
}

# run_timeout <seconds> <cmd...> : runs cmd, kills it after N seconds.
# Returns cmd's status, or 124 on timeout.
run_timeout() {
    _rt_s="$1"; shift
    "$@" &
    _rt_pid=$!
    ( sleep "$_rt_s"; kill "$_rt_pid" 2>/dev/null ) &
    _rt_w=$!
    wait "$_rt_pid"; _rt_rc=$?
    if kill -0 "$_rt_w" 2>/dev/null; then
        kill "$_rt_w" 2>/dev/null; wait "$_rt_w" 2>/dev/null
    else
        _rt_rc=124
    fi
    return "$_rt_rc"
}

json_str() {  # escape for a JSON string value
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr -d '\r\n'
}

valid_name() {
    case "$1" in
        ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    [ "${#1}" -le 64 ]
}
sanitize_name() {
    printf '%s' "$1" | sed 's/\.conf$//; s/[^A-Za-z0-9._-]/_/g; s/^\.*//' | cut -c1-64
}
profile_path() { printf '%s/%s.conf' "$CONF_DIR" "$1"; }

# ---------------------------------------------------------------------------
# .conf parsing (wg-quick format). Sets P_* variables. Never echoes secrets.
#   P_PRIV P_ADDR P_MTU P_PUB P_PSK P_EP P_ALLOWED P_KA P_PEERS P_IGNORED
# Values are read through a here-document (no eval) so file contents can
# never be executed.
# ---------------------------------------------------------------------------
conf_parse() {
    P_PRIV=; P_ADDR=; P_MTU=; P_PUB=; P_PSK=; P_EP=; P_ALLOWED=; P_KA=; P_PEERS=0; P_IGNORED=
    [ -r "$1" ] || return 1
    _cp_out=$(awk '
        function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
        {
            line = $0
            sub(/#.*/, "", line)          # wg-quick strips comments the same way
            line = trim(line)
            if (line == "") next
            if (line ~ /^\[[Ii]nterface\]$/) { sec = "i"; next }
            if (line ~ /^\[[Pp]eer\]$/)      { sec = "p"; peers++; next }
            if (line ~ /^\[/)                { sec = "?"; next }
            eq = index(line, "=")
            if (eq == 0) next
            k = tolower(trim(substr(line, 1, eq - 1)))
            v = trim(substr(line, eq + 1))
            gsub(/[ \t]/, "", v)
            if (sec == "i") {
                if (k == "privatekey") print "PRIV\t" v
                else if (k == "address") print "ADDR\t" v
                else if (k == "mtu") print "MTU\t" v
                else if (k == "dns") { }   # expected in provider configs; DNS is left to the router
                else print "IGN\t" k
            } else if (sec == "p" && peers == 1) {
                if (k == "publickey") print "PUB\t" v
                else if (k == "presharedkey") print "PSK\t" v
                else if (k == "endpoint") print "EP\t" v
                else if (k == "allowedips") print "ALLOWED\t" v
                else if (k == "persistentkeepalive") print "KA\t" v
                else print "IGN\t" k
            }
        }
        END { print "PEERS\t" (peers + 0) }
    ' "$1") || return 1
    while IFS="$TAB" read -r _cp_k _cp_v; do
        case "$_cp_k" in
            PRIV) P_PRIV=$_cp_v ;;
            ADDR) P_ADDR="${P_ADDR:+$P_ADDR,}$_cp_v" ;;
            MTU) P_MTU=$_cp_v ;;
            PUB) P_PUB=$_cp_v ;;
            PSK) P_PSK=$_cp_v ;;
            EP) P_EP=$_cp_v ;;
            ALLOWED) P_ALLOWED="${P_ALLOWED:+$P_ALLOWED,}$_cp_v" ;;
            KA) P_KA=$_cp_v ;;
            PEERS) P_PEERS=$_cp_v ;;
            IGN) P_IGNORED="${P_IGNORED:+$P_IGNORED }$_cp_v" ;;
        esac
    done <<EOF
$_cp_out
EOF
    # endpoint split: host:port, [v6]:port
    P_EP_HOST=; P_EP_PORT=
    case "$P_EP" in
        \[*\]:*) P_EP_HOST=${P_EP#\[}; P_EP_HOST=${P_EP_HOST%%\]*}; P_EP_PORT=${P_EP##*\]:} ;;
        *:*)     P_EP_HOST=${P_EP%:*}; P_EP_PORT=${P_EP##*:} ;;
    esac
    return 0
}

is_wg_key() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$'; }
is_ipv4() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
is_ipv6() { case "$1" in *:*) printf '%s' "$1" | grep -Eq '^[0-9A-Fa-f:.]+$' ;; *) return 1 ;; esac; }

# conf_validate: run after conf_parse. Prints the reason on failure.
conf_validate() {
    [ "$P_PEERS" = 1 ] || { echo "must contain exactly one [Peer] section (found $P_PEERS)"; return 1; }
    is_wg_key "$P_PRIV" || { echo "[Interface] PrivateKey is missing or not a valid WireGuard key"; return 1; }
    is_wg_key "$P_PUB" || { echo "[Peer] PublicKey is missing or not a valid WireGuard key"; return 1; }
    [ -z "$P_PSK" ] || is_wg_key "$P_PSK" || { echo "[Peer] PresharedKey is not a valid WireGuard key"; return 1; }
    [ -n "$P_ADDR" ] || { echo "[Interface] Address is missing"; return 1; }
    printf '%s' "$P_ADDR" | grep -Eq '^[0-9A-Fa-f:./,]+$' || { echo "[Interface] Address contains unexpected characters"; return 1; }
    [ -n "$P_EP_HOST" ] && is_uint "$P_EP_PORT" && [ "$P_EP_PORT" -ge 1 ] && [ "$P_EP_PORT" -le 65535 ] \
        || { echo "[Peer] Endpoint must be host:port"; return 1; }
    printf '%s' "$P_EP_HOST" | grep -Eq '^[A-Za-z0-9.:-]+$' || { echo "[Peer] Endpoint host contains unexpected characters"; return 1; }
    [ -n "$P_ALLOWED" ] || { echo "[Peer] AllowedIPs is missing"; return 1; }
    printf '%s' "$P_ALLOWED" | grep -Eq '^[0-9A-Fa-f:./,]+$' || { echo "[Peer] AllowedIPs contains unexpected characters"; return 1; }
    [ -z "$P_MTU" ] || { is_uint "$P_MTU" && [ "$P_MTU" -ge 576 ] && [ "$P_MTU" -le 9000 ]; } || { echo "MTU must be 576-9000"; return 1; }
    [ -z "$P_KA" ] || { is_uint "$P_KA" && [ "$P_KA" -le 65535 ]; } || { echo "PersistentKeepalive must be 0-65535"; return 1; }
    return 0
}

# profile_load <name>: parse + validate; sets P_* (and P_ERR on failure).
# Must NOT be called inside $(...) - that would lose the P_* variables.
profile_load() {
    P_ERR=
    valid_name "$1" || { P_ERR="invalid profile name '$1'"; return 1; }
    _pl_f=$(profile_path "$1")
    [ -f "$_pl_f" ] || { P_ERR="no such profile '$1' ($_pl_f)"; return 1; }
    conf_parse "$_pl_f" || { P_ERR="cannot read $_pl_f"; return 1; }
    P_ERR=$(conf_validate) || return 1
    P_ERR=
    return 0
}

ep_display() {  # ep_display <host> <port> -> host:port, [v6]:port
    case "$1" in *:*) printf '[%s]:%s' "$1" "$2" ;; *) printf '%s:%s' "$1" "$2" ;; esac
}

profiles() {  # list valid-named profile names, sorted
    for _pf in "$CONF_DIR"/*.conf; do
        [ -f "$_pf" ] || continue
        _pn=${_pf##*/}; _pn=${_pn%.conf}
        valid_name "$_pn" && printf '%s\n' "$_pn"
    done | sort
}

# ---------------------------------------------------------------------------
# endpoint resolution, with a persistent cache so failover works when DNS
# is down (e.g. DNS itself goes through the dead tunnel).
# ---------------------------------------------------------------------------
endpoint_ip() {  # endpoint_ip <host> -> ip on stdout
    if is_ipv4 "$1" || is_ipv6 "$1"; then printf '%s' "$1"; return 0; fi
    _ei_ip=$(run_timeout 4 nslookup "$1" 2>/dev/null | awk '
        /^Name:/ { named = 1; next }
        named && /^Address/ { sub(/^Address[ 0-9]*:[ \t]*/, ""); split($0, a, " "); print a[1]; exit }')
    if [ -n "$_ei_ip" ] && { is_ipv4 "$_ei_ip" || is_ipv6 "$_ei_ip"; }; then
        mkdir -p "$WGS_ETC" 2>/dev/null
        if [ "$(awk -v h="$1" '$1 == h { print $2 }' "$WGS_EPCACHE" 2>/dev/null)" != "$_ei_ip" ]; then
            { grep -v "^$1 " "$WGS_EPCACHE" 2>/dev/null; printf '%s %s\n' "$1" "$_ei_ip"; } > "$WGS_EPCACHE.tmp" \
                && mv "$WGS_EPCACHE.tmp" "$WGS_EPCACHE"
        fi
        printf '%s' "$_ei_ip"; return 0
    fi
    _ei_ip=$(awk -v h="$1" '$1 == h { print $2 }' "$WGS_EPCACHE" 2>/dev/null)
    [ -n "$_ei_ip" ] && { printf '%s' "$_ei_ip"; return 0; }
    return 1
}

# ---------------------------------------------------------------------------
# netifd (uci network) - only the interface's WireGuard fields, its peers
# (all of type wireguard_<iface>) and its four /1 route sections are owned
# by wgswitch. Other options on the interface (zones, metrics...) are kept.
# ---------------------------------------------------------------------------
net_apply_profile() {  # after profile_load; $1 = endpoint host to write
    uci -q get "network.$IFACE" >/dev/null 2>&1 || uci set "network.$IFACE=interface"
    uci set "network.$IFACE.proto=wireguard"
    uci set "network.$IFACE.private_key=$P_PRIV"
    uci -q delete "network.$IFACE.addresses" 2>/dev/null || true
    _na_old=$IFS; IFS=','
    for _a in $P_ADDR; do [ -n "$_a" ] && uci add_list "network.$IFACE.addresses=$_a"; done
    IFS=$_na_old
    if [ -n "$P_MTU" ]; then uci set "network.$IFACE.mtu=$P_MTU"; else uci -q delete "network.$IFACE.mtu" 2>/dev/null || true; fi
    uci set "network.$IFACE.auto=1"

    for _s in $(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)=wireguard_$IFACE\$/\1/p"); do
        uci -q delete "network.$_s" 2>/dev/null || true
    done
    _np="${IFACE}_peer"
    uci set "network.$_np=wireguard_$IFACE"
    uci set "network.$_np.description=wgswitch"
    uci set "network.$_np.public_key=$P_PUB"
    if [ -n "$P_PSK" ]; then uci set "network.$_np.preshared_key=$P_PSK"; fi
    uci set "network.$_np.endpoint_host=$1"
    uci set "network.$_np.endpoint_port=$P_EP_PORT"
    uci set "network.$_np.persistent_keepalive=${P_KA:-25}"
    _na_old=$IFS; IFS=','
    for _a in $P_ALLOWED; do [ -n "$_a" ] && uci add_list "network.$_np.allowed_ips=$_a"; done
    IFS=$_na_old

    for _r in def4_lo def4_hi def6_lo def6_hi; do uci -q delete "network.${IFACE}_$_r" 2>/dev/null || true; done
    _al=",$P_ALLOWED,"
    case "$ROUTE_MODE" in
        split)
            # Two /1 halves instead of a /0: always more specific than the
            # existing default route, never replace it (netifd adds routes
            # with NLM_F_REPLACE), so `ifdown` restores the previous default.
            uci set "network.$_np.route_allowed_ips=0"
            case "$_al" in
                *,0.0.0.0/0,*)
                    _net_route route "${IFACE}_def4_lo" 0.0.0.0/1
                    _net_route route "${IFACE}_def4_hi" 128.0.0.0/1 ;;
            esac
            case "$_al" in
                *,::/0,*|*,::0/0,*)
                    _net_route route6 "${IFACE}_def6_lo" ::/1
                    _net_route route6 "${IFACE}_def6_hi" 8000::/1 ;;
            esac
            case "$_al" in
                *,0.0.0.0/0,*|*,::/0,*|*,::0/0,*) ;;
                *) uci set "network.$_np.route_allowed_ips=1" ;;   # split tunnel: route just those prefixes
            esac
            ;;
        allowed_ips) uci set "network.$_np.route_allowed_ips=1" ;;
        none) uci set "network.$_np.route_allowed_ips=0" ;;
    esac
}
_net_route() {
    uci set "network.$2=$1"
    uci set "network.$2.interface=$IFACE"
    uci set "network.$2.target=$3"
}

iface_exists() { wg show "$IFACE" public-key >/dev/null 2>&1; }
latest_handshake() {  # epoch of the newest handshake on <dev>, 0 if none
    wg show "$1" latest-handshakes 2>/dev/null | awk 'BEGIN { m = 0 } $2 > m { m = $2 } END { print m + 0 }'
}
live_peer_pub() { wg show "$IFACE" peers 2>/dev/null | head -n1; }

wait_handshake() {  # wait_handshake <dev> <since-epoch> <timeout-s>
    _wh_end=$(( $(now) + $3 ))
    while [ "$(now)" -le "$_wh_end" ]; do
        _wh_h=$(latest_handshake "$1")
        [ "$_wh_h" -ge "$2" ] && [ "$_wh_h" -gt 0 ] && return 0
        nap 250000
    done
    return 1
}

# ---------------------------------------------------------------------------
# hooks: one executable, called with "connect" or "disconnect".
# Used e.g. to tell another router to start/stop sending traffic here.
# ---------------------------------------------------------------------------
run_hook() {  # run_hook <action>
    [ -n "$HOOK" ] || return 0
    [ -x "$HOOK" ] || { log_err "hook '$HOOK' is not an executable file"; return 1; }
    log_info "running hook: $HOOK $1"
    WGSWITCH_ACTION="$1" WGSWITCH_INTERFACE="$IFACE" WGSWITCH_PROFILE="$(state_get profile)" \
        run_timeout "$HOOK_TIMEOUT" "$HOOK" "$1"
    _rh_rc=$?
    [ "$_rh_rc" = 0 ] || log_err "hook '$HOOK $1' failed (exit $_rh_rc)"
    return "$_rh_rc"
}

# ---------------------------------------------------------------------------
# health: handshake age + ping through the tunnel. Writes $WGS_HEALTH.
# ---------------------------------------------------------------------------
health_check() {
    H_UP=0; H_AGE=-1; H_RTT=; H_LOSS=100; H_RX=0; H_TX=0; H_OK=0
    if iface_exists; then
        H_UP=1
        _hc_h=$(latest_handshake "$IFACE")
        [ "$_hc_h" -gt 0 ] && H_AGE=$(( $(now) - _hc_h ))
        # shellcheck disable=SC2046
        set -- $(wg show "$IFACE" transfer 2>/dev/null | awk '{ rx += $2; tx += $3 } END { print rx + 0, tx + 0 }')
        H_RX=${1:-0}; H_TX=${2:-0}
        _hc_sent=0; _hc_recv=0; _hc_sum=0; _hc_n=0
        for _t in $PING_TARGETS; do
            # shellcheck disable=SC2046
            set -- $(ping -c 3 -W 2 -I "$IFACE" "$_t" 2>/dev/null | awk '
                # BusyBox: "3 packets transmitted, 3 packets received, 0% packet loss"
                # iputils: "3 packets transmitted, 3 received, 0% packet loss, time 2003ms"
                /packets transmitted/ {
                    n = split($0, w, /[ ,]+/)
                    for (i = 1; i < n; i++) {
                        if (w[i] !~ /^[0-9]+$/) continue
                        if (w[i+1] == "packets" && w[i+2] == "transmitted") s = w[i]
                        if (w[i+1] == "received" || (w[i+1] == "packets" && w[i+2] == "received")) r = w[i]
                    }
                }
                /round-trip|rtt/ { split($0, p, "="); split(p[2], q, "/"); avg = q[2] }
                END { printf "%d %d %s\n", s + 0, r + 0, (avg == "" ? "-" : avg) }')
            _hc_sent=$((_hc_sent + ${1:-0})); _hc_recv=$((_hc_recv + ${2:-0}))
            if [ "${3:--}" != "-" ]; then
                _hc_sum=$(awk -v a="$_hc_sum" -v b="$3" 'BEGIN { printf "%.1f", a + b }'); _hc_n=$((_hc_n + 1))
            fi
        done
        [ "$_hc_sent" -gt 0 ] && H_LOSS=$(( (_hc_sent - _hc_recv) * 100 / _hc_sent ))
        [ "$_hc_n" -gt 0 ] && H_RTT=$(awk -v a="$_hc_sum" -v n="$_hc_n" 'BEGIN { printf "%.1f", a / n }')
        if [ "$H_AGE" -ge 0 ] && [ "$H_AGE" -le "$HS_MAX" ] && [ "$_hc_recv" -gt 0 ]; then H_OK=1; fi
    fi
    printf 'ok=%s up=%s age=%s rtt=%s loss=%s rx=%s tx=%s ts=%s\n' \
        "$H_OK" "$H_UP" "$H_AGE" "${H_RTT:--}" "$H_LOSS" "$H_RX" "$H_TX" "$(now)" > "$WGS_HEALTH.tmp" \
        && mv "$WGS_HEALTH.tmp" "$WGS_HEALTH"
    [ "$H_OK" = 1 ]
}

# ---------------------------------------------------------------------------
# probe: bare WireGuard handshake through ONE temporary interface that is
# never in uci (so never in LuCI) and always deleted afterwards. Its
# encrypted packets carry $FWMARK and are routed via the underlay gateway
# (the default route that isn't the tunnel), never into the live tunnel.
# The timing includes the server's own processing, so a busy server that
# answers with a WireGuard cookie (its "under load" signal) shows up as a
# ~5 s handshake.
# ---------------------------------------------------------------------------
wg_link_add() {
    if [ -n "${WGSWITCH_WG_USERSPACE:-}" ]; then "$WGSWITCH_WG_USERSPACE" "$1" >/dev/null 2>&1
    else ip link add dev "$1" type wireguard 2>/dev/null; fi
}

# Probe packets (fwmark $FWMARK) use two rules:
#   1. main table, but ignoring routes with prefix length <= 1: every
#      specific route still applies (LAN, static routes, the live tunnel's
#      own endpoint host route), while the tunnel's /1 halves and any
#      default route are skipped;
#   2. $PROBE_TABLE: a copy of the underlay default route (the default
#      route that is not via the tunnel).
probe_rules() {  # the two rule specs, one per line
    printf 'fwmark %s lookup main suppress_prefixlength 1 priority %s\n' "$FWMARK" "$PROBE_PRIO"
    printf 'fwmark %s lookup %s priority %s\n' "$FWMARK" "$PROBE_TABLE" "$((PROBE_PRIO + 1))"
}
probe_begin() {  # sets up the policy rules; call once per test run
    probe_end
    _pb_ok=0
    _pb_specs=$(probe_rules)
    for _fam in 4 6; do
        _pb_r=$(ip -"$_fam" route show default 2>/dev/null | grep -v "dev $IFACE\( \|$\)" | grep -v "dev $PROBE_IF\( \|$\)" | head -n1)
        [ -n "$_pb_r" ] || continue
        # shellcheck disable=SC2086
        ip -"$_fam" route replace $_pb_r table "$PROBE_TABLE" 2>/dev/null || continue
        _pb_fam_ok=1
        while read -r _pb_spec; do
            # shellcheck disable=SC2086
            ip -"$_fam" rule add $_pb_spec 2>/dev/null || _pb_fam_ok=0
        done <<RULES
$_pb_specs
RULES
        [ "$_pb_fam_ok" = 1 ] && _pb_ok=1
    done
    [ "$_pb_ok" = 1 ] || { log_err "probe: no underlay default route found (a default route that is not via $IFACE)"; return 1; }
    return 0
}
probe_end() {
    ip link del dev "$PROBE_IF" 2>/dev/null || true
    _pe_specs=$(probe_rules)
    for _fam in 4 6; do
        while read -r _pe_spec; do
            # shellcheck disable=SC2086
            while ip -"$_fam" rule del $_pe_spec 2>/dev/null; do :; done
        done <<RULES
$_pe_specs
RULES
        ip -"$_fam" route flush table "$PROBE_TABLE" 2>/dev/null || true
    done
    rm -f "$WGS_RUN/probe.key" "$WGS_RUN/probe.psk" 2>/dev/null || true
}

# probe_one <name>  -> prints "ok <ms>" | "fail <reason>" ; needs probe_begin
probe_one() {
    profile_load "$1" || { echo "fail invalid: $P_ERR"; return 1; }
    _po_ip=$(endpoint_ip "$P_EP_HOST") || { echo "fail dns"; return 1; }
    ip link del dev "$PROBE_IF" 2>/dev/null || true
    wg_link_add "$PROBE_IF" || { echo "fail cannot-create-interface"; return 1; }
    ( umask 077; printf '%s\n' "$P_PRIV" > "$WGS_RUN/probe.key" )
    if ! wg set "$PROBE_IF" fwmark "$FWMARK" private-key "$WGS_RUN/probe.key" 2>/dev/null; then
        rm -f "$WGS_RUN/probe.key"; ip link del dev "$PROBE_IF" 2>/dev/null
        echo "fail wg-set"; return 1
    fi
    rm -f "$WGS_RUN/probe.key"
    ip link set dev "$PROBE_IF" up 2>/dev/null
    case "$_po_ip" in *:*) _po_ep="[$_po_ip]:$P_EP_PORT" ;; *) _po_ep="$_po_ip:$P_EP_PORT" ;; esac
    _po_t0=$(uptime_ms)
    if [ -n "$P_PSK" ]; then
        ( umask 077; printf '%s\n' "$P_PSK" > "$WGS_RUN/probe.psk" )
        wg set "$PROBE_IF" peer "$P_PUB" preshared-key "$WGS_RUN/probe.psk" endpoint "$_po_ep" persistent-keepalive 1 2>/dev/null
        rm -f "$WGS_RUN/probe.psk"
    else
        wg set "$PROBE_IF" peer "$P_PUB" endpoint "$_po_ep" persistent-keepalive 1 2>/dev/null
    fi
    _po_lim=$(( _po_t0 + PROBE_TIMEOUT * 1000 ))
    # Second, independent bound on the wall clock: no clock bug may ever
    # make this loop endless again.
    _po_deadline=$(( $(now) + PROBE_TIMEOUT + 1 ))
    _po_res="fail timeout"
    while [ "$(uptime_ms)" -le "$_po_lim" ] && [ "$(now)" -le "$_po_deadline" ]; do
        if [ "$(latest_handshake "$PROBE_IF")" -gt 0 ]; then
            _po_res="ok $(( $(uptime_ms) - _po_t0 ))"; break
        fi
        nap 50000
    done
    ip link del dev "$PROBE_IF" 2>/dev/null || true
    echo "$_po_res"
    case "$_po_res" in ok*) return 0 ;; *) return 1 ;; esac
}

# results file: name \t status(ok|fail|active) \t ms \t epoch \t detail
results_put() {  # results_put <name> <status> <ms> <detail>
    _rp_line="$1$TAB$2$TAB$3$TAB$(now)$TAB$4"
    { awk -F "$TAB" -v n="$1" '$1 != n' "$WGS_RESULTS" 2>/dev/null; printf '%s\n' "$_rp_line"; } > "$WGS_RESULTS.tmp" \
        && mv "$WGS_RESULTS.tmp" "$WGS_RESULTS"
}
result_of() { awk -F "$TAB" -v n="$1" '$1 == n { print; exit }' "$WGS_RESULTS" 2>/dev/null; }

# ranked <exclude-name>: candidates, best first: ok by ms, then untested, then failed
ranked() {
    profiles | while read -r _n; do
        [ "$_n" = "$1" ] && continue
        _r=$(result_of "$_n")
        if [ -z "$_r" ]; then printf '1 0 %s\n' "$_n"
        else
            _st=$(printf '%s' "$_r" | cut -f2); _ms=$(printf '%s' "$_r" | cut -f3)
            case "$_st" in ok|active) printf '0 %s %s\n' "${_ms:-0}" "$_n" ;; *) printf '2 0 %s\n' "$_n" ;; esac
        fi
    done | sort -k1,1n -k2,2n | awk '{ print $3 }'
}

# test_run <names...> : probe each, sequentially, through the single probe
# interface. Holds the "probe" lock. Writes progress for LuCI.
_test_cleanup() { probe_end; lock_release probe; rm -f "$WGS_PROGRESS"; }
test_run() {  # run it in a subshell: ( test_run a b c ) - it sets traps
    lock_wait probe "${TEST_LOCK_WAIT:-600}" || { log_err "another test is still running"; return 1; }
    trap '_test_cleanup' EXIT
    trap '_test_cleanup; trap - EXIT; exit 130' INT TERM
    _tr_total=$#; _tr_done=0; _tr_ok=0
    printf 'running 0 %s %s\n' "$_tr_total" "$(now)" > "$WGS_PROGRESS"
    probe_begin || return 1
    _tr_live=; [ "$(state_get enabled)" = 1 ] && _tr_live=$(live_peer_pub)
    for _n in "$@"; do
        _tr_done=$((_tr_done + 1))
        if profile_load "$_n" && [ -n "$_tr_live" ] && [ "$P_PUB" = "$_tr_live" ] && [ "$_n" = "$(state_get profile)" ]; then
            # Never probe the server we are connected to: the same key from a
            # second socket would make the server roam our live session.
            results_put "$_n" active "" "connected - see live health"
            printf '%s\tactive\n' "$_n"
        else
            # shellcheck disable=SC2046
            set -- $(probe_one "$_n")
            if [ "$1" = ok ]; then
                results_put "$_n" ok "$2" ""; _tr_ok=$((_tr_ok + 1))
                printf '%s\tok\t%s ms\n' "$_n" "$2"
            else
                shift; results_put "$_n" fail "" "$*"
                printf '%s\tfail\t%s\n' "$_n" "$*"
            fi
        fi
        printf 'running %s %s %s\n' "$_tr_done" "$_tr_total" "$(now)" > "$WGS_PROGRESS"
    done
    trap - EXIT INT TERM
    probe_end
    lock_release probe
    printf 'done %s %s %s\n' "$_tr_done" "$_tr_total" "$(now)" > "$WGS_PROGRESS"
    log_info "test finished: $_tr_ok of $_tr_total servers answered"
    return 0
}

best_result() {  # best ok profile by ms, optionally excluding $1
    awk -F "$TAB" -v x="${1:-}" '$2 == "ok" && $1 != x { print $3 "\t" $1 }' "$WGS_RESULTS" 2>/dev/null \
        | sort -n | head -n1 | cut -f2
}
