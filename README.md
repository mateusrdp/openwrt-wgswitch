# wgswitch: WireGuard profile switcher for OpenWrt

Keep many WireGuard client profiles (the `.conf` files your VPN provider
gives you), connect to one at a time, find the fastest server with a real
WireGuard handshake test, and keep watch over the live tunnel with a kill
switch. Comes as a CLI and a LuCI page (**Network › VPN**).

- **One interface.** Connecting replaces the profile on a single netifd
  interface (name configurable, e.g. `wg0` or `vpn`). Switching servers
  disconnects the current one first. A failed connect rolls back to the
  previous working state.
- **Profiles are plain files** in `/etc/wireguard/*.conf` (wg-quick format).
  Upload them in LuCI or copy them there yourself: either way they're listed.
- **Server test = a real WireGuard handshake**, not a ping. See
  [How the server test works](#how-the-server-test-works).
- **Health checks** every 15 s: handshake age, plus round-trip time and
  packet loss *through* the tunnel.
- **Kill switch** with three modes: `block`, `fastest` or `direct`.
- **Optional hook** for multi-router setups, e.g. telling another router to
  start or stop sending traffic to this one.

Requires OpenWrt 25.12 or newer (apk). Pulls in `wireguard-tools`,
`kmod-wireguard` and `ip-full`. The packages are architecture-independent.

## Install

From the signed feed (recommended: `apk upgrade` then keeps it current):

```sh
wget -O /etc/apk/keys/wgswitch.pem https://mateusrdp.github.io/openwrt-wgswitch/wgswitch.pem
echo 'https://mateusrdp.github.io/openwrt-wgswitch/packages.adb' > /etc/apk/repositories.d/wgswitch.list
apk update && apk add wgswitch luci-app-wgswitch
```

Or download the `.apk` files from
[Releases](https://github.com/mateusrdp/openwrt-wgswitch/releases) and
`apk add --allow-untrusted ./wgswitch-*.apk ./luci-app-wgswitch-*.apk`.

## Set up

1. **Pick the interface name** and set it:
   `uci set wgswitch.main.interface='wg0'; uci commit wgswitch`
   (or in LuCI › Network › VPN › Settings). wgswitch creates or updates that
   netifd interface. It only owns the interface's WireGuard fields, its
   peers and the four route sections `<iface>_def4_lo/hi`, `<iface>_def6_lo/hi`;
   other options you set on the interface are left alone.
2. **Firewall.** Put the device in a zone with masquerading, and forward
   your LAN into it. Match it by **device**, not network: a WireGuard
   interface has no device until it's up, so a `list network` match can
   resolve to nothing when the firewall loads first.
   ```
   config zone
           option name 'vpn'
           list device 'wg0'
           option input 'REJECT'
           option output 'ACCEPT'
           option forward 'REJECT'
           option masq '1'
           option mtu_fix '1'
   config forwarding
           option src 'lan'
           option dest 'vpn'
   ```
   For a real kill switch, `lan` must **not** also be allowed to forward to
   `wan` (see [Kill switch](#kill-switch)).
3. **Add profiles:** copy `.conf` files to `/etc/wireguard/` (mode 600), or
   `wgswitch add provider-au45.conf AU-45`, or use LuCI's *Add profile…*.
4. `wgswitch test`, then `wgswitch connect <fastest>` (or `connect --best`).

## CLI

```
wgswitch list [--json]                 profiles + last test result
wgswitch show <name> [--secrets]       keys hidden unless --secrets
wgswitch add <file> [name] [--replace] validate + install a .conf
wgswitch edit <name>                   $EDITOR, validated on save
wgswitch remove <name>                 refuses the connected profile
wgswitch connect <name> | --best       switch (disconnects the current one first)
                 [--no-hook]           ...without running the connect hook
wgswitch reconnect | disconnect
wgswitch status [--json]               server, handshake age, RTT, loss, state
wgswitch test [name...]                handshake-test profiles (default: all)
wgswitch best                          fastest from the last test
wgswitch killswitch [block|fastest|direct]
```

`connect`, `reconnect`, `disconnect` and `test` accept `--bg` to hand the
job to the background service (that's what LuCI does, so a slow connect is
never cut off by the web UI's request timeout).

## How the server test works

For each profile, sequentially, through **one** temporary interface
(`wgsprobe`, never in uci, so never in LuCI, and deleted afterwards):

1. load that profile's key and peer, with no address and no routes;
2. mark its encrypted packets (`fwmark 0x5157`) so they leave via your
   normal uplink, never into the live tunnel. Specific routes (LAN, static
   routes) still apply; only the tunnel's `/1` halves and the default route
   are swapped for the underlay's default;
3. time the WireGuard handshake.

A completed handshake proves the server is up and accepts **your key**
(so a full server or a device-limit rejection counts as a failure, unlike
with ping). The time includes the server's own processing. A server under
load answers with a WireGuard *cookie* first, which shows up as a
handshake of 5 s or more.

Limits: it measures how responsive a server is, not its bandwidth. The
**connected** profile is never probed (the same key from a second socket
would make the server move your live session); its live health is shown
instead. Each probe briefly counts as one connection against your
provider's device limit.

## Kill switch

Checked every `check_interval` (15 s). After `fail_threshold` (3) failed
checks in a row (handshake older than `handshake_timeout`, or no ping reply
through the tunnel):

| mode | what happens |
|---|---|
| `block` | Nothing goes around the tunnel: it stays the only route, so traffic stops until it recovers. wgswitch keeps retrying the connection. Requires that your firewall has no `lan → wan` forwarding. |
| `fastest` | Tests the best `failover_candidates` (5) other profiles, using the last results to pick the order, and connects to the fastest one that answers. If none does, behaves like `block` and retries. |
| `direct` | Disconnects: runs the `disconnect` hook, takes the interface down, and traffic goes out directly. Stays disconnected until you connect again. |

A `disconnect` you ask for never triggers the kill switch.

## Hook

`option hook '/etc/wgswitch/hook.sh'` - an executable called with
`connect` (after connecting from a disconnected state) or `disconnect`
(before disconnecting). Environment: `WGSWITCH_ACTION`,
`WGSWITCH_INTERFACE`, `WGSWITCH_PROFILE`. A non-zero exit is reported (exit
status 3) but doesn't undo the tunnel change. Example: a VPN box that sits
behind another router, which has to start or stop routing clients to it:

```sh
#!/bin/sh
exec ssh -i /etc/wgswitch/hook_key -y root@192.168.1.1 "$1"   # forced-command key on the other router
```

## Configuration (`/etc/config/wgswitch`)

| option | default | |
|---|---|---|
| `interface` | `wg0` | netifd interface / WireGuard device name (max 15 chars) |
| `conf_dir` | `/etc/wireguard` | profile folder |
| `killswitch` | `block` | `block` \| `fastest` \| `direct` |
| `route_mode` | `split` | `split`: full-tunnel profiles get `0.0.0.0/1` + `128.0.0.0/1` (and `::/1` + `8000::/1`), keeping your default route underneath so `disconnect` restores it. `allowed_ips`: netifd's Route Allowed IPs. `none`: no routes (e.g. use pbr). |
| `check_interval` | `15` | seconds between health checks |
| `fail_threshold` | `3` | failed checks before the kill switch acts |
| `handshake_timeout` | `180` | max handshake age (s) |
| `ping_target` | `1.1.1.1`, `1.0.0.1` | pinged through the tunnel |
| `connect_timeout` | `20` | seconds to wait for a handshake on connect |
| `probe_timeout` | `7` | per-server test timeout (above 5 s, so cookie replies register as slow, not dead) |
| `failover_candidates` | `5` | servers tested by `fastest` |
| `hook`, `hook_timeout` | - , `90` | see [Hook](#hook) |
| `probe_interface`, `fwmark`, `probe_table`, `probe_rule_priority` | `wgsprobe`, `0x5157`, `5157`, `5157` | change only if they clash |

`/etc/wireguard/` and `/etc/wgswitch/` are kept across sysupgrade.

## Security notes

- Profiles are stored mode 600 in a mode 700 folder. Keys never appear in
  logs or `status`/`list` output, and `show` hides them unless you pass
  `--secrets`. LuCI's editor shows them to logged-in admins, who are root
  anyway.
- Nothing in a `.conf` is ever executed: wg-quick's `PostUp`/`PreDown`
  etc. are ignored, with a warning. `DNS =` is ignored too; DNS stays
  whatever your router uses.
- As with any WireGuard setup on OpenWrt, the active key also lives in
  `/etc/config/network`.

## Development

```sh
sh tests/run.sh -v               # flow tests under BusyBox ash, simulated network (no root)
sudo sh tests/integration.sh     # real WireGuard handshakes in network namespaces
sh scripts/check-secrets.sh --all
```

After a fresh clone run `sh scripts/dev-setup.sh` once (it activates the
secret-guard hook). `setup-claude.sh` (repo owner, once) protects `main`,
turns on GitHub secret scanning and sets the repo up for Claude Code.

CI (`.github/workflows/build.yml`) runs the secret scan over the whole
history, shellcheck, both test suites, and an OpenWrt 25.12 SDK build. A
`v*` tag also publishes a GitHub Release and the signed feed on GitHub
Pages. **Never commit `.conf` files, keys or credentials.** The pre-commit
hook (`git config core.hooksPath .githooks`) and CI both refuse them.

License: GPL-2.0-only.
