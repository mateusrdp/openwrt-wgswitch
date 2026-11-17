#!/usr/bin/env python3
"""
Test doubles for the OpenWrt tools wgswitch calls: uci, wg, ip, ifup,
ifdown, ping, nslookup, logger, usleep, id. One script, dispatched on the
name it is invoked as (tests/shims/<tool> are symlinks to this file).

State lives under $FAKE (a temp dir per test):
  uci/<config>          uci config as JSON
  wg/<dev>.json         WireGuard devices: {peer, endpoint, hs, fwmark}
  net/reachable         "ip delay_ms" lines: endpoints that answer handshakes
  net/routes4           output of `ip -4 route show default`
  net/rules, net/tables kernel policy-routing state touched by the probe
  log/calls             every hook/ifup/ifdown call, for assertions
  log/keyfiles          private-key files seen by `wg set` (must be gone later)
"""
import json, os, sys, time, re

FAKE = os.environ["FAKE"]
def p(*a): return os.path.join(FAKE, *a)
def rd(path, default=""):
    try:
        with open(path) as f: return f.read()
    except FileNotFoundError: return default
def wr(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f: f.write(data)
def log(line):
    os.makedirs(p("log"), exist_ok=True)
    with open(p("log", "calls"), "a") as f: f.write(line + "\n")

# ------------------------------------------------------------------ uci
def uci_load(cfg):
    return json.loads(rd(p("uci", cfg), "{}"))  # {section: {".type": t, opt: str|list}}
def uci_save(cfg, d): wr(p("uci", cfg), json.dumps(d, indent=1))

def uci_main(argv):
    quiet = False
    args = []
    for a in argv:
        if a == "-q": quiet = True
        else: args.append(a)
    if not args: return 1
    cmd, rest = args[0], args[1:]
    def fail():
        if not quiet: print("uci: Entry not found", file=sys.stderr)
        return 1
    if cmd in ("get", "set", "delete", "add_list"):
        expr = rest[0] if rest else ""
        val = None
        if "=" in expr and cmd in ("set", "add_list"):
            expr, val = expr.split("=", 1)
        parts = expr.split(".")
        cfg = parts[0]; d = uci_load(cfg)
        if cmd == "get":
            if len(parts) == 2:
                s = d.get(parts[1]);
                if s is None: return fail()
                print(s[".type"]); return 0
            s = d.get(parts[1], {}); v = s.get(parts[2]) if len(parts) == 3 else None
            if v is None: return fail()
            print(" ".join(v) if isinstance(v, list) else v); return 0
        if cmd == "set":
            if len(parts) == 2: d.setdefault(parts[1], {})[".type"] = val; d[parts[1]][".type"] = val
            else:
                if parts[1] not in d: return fail()
                d[parts[1]][parts[2]] = val
            uci_save(cfg, d); return 0
        if cmd == "add_list":
            if parts[1] not in d: return fail()
            cur = d[parts[1]].get(parts[2], [])
            if not isinstance(cur, list): cur = [cur]
            cur.append(val); d[parts[1]][parts[2]] = cur; uci_save(cfg, d); return 0
        if cmd == "delete":
            if len(parts) == 2:
                if parts[1] not in d: return fail()
                del d[parts[1]]
            else:
                if parts[2] not in d.get(parts[1], {}): return fail()
                del d[parts[1]][parts[2]]
            uci_save(cfg, d); return 0
    if cmd == "commit": return 0
    if cmd == "show":
        cfg = rest[0]; d = uci_load(cfg)
        for s, o in d.items():
            print(f"{cfg}.{s}={o['.type']}")
            for k, v in o.items():
                if k == ".type": continue
                vv = " ".join(f"'{x}'" for x in v) if isinstance(v, list) else f"'{v}'"
                print(f"{cfg}.{s}.{k}={vv}")
        return 0
    if cmd == "export":
        print(rd(p("uci", rest[0]), "{}")); return 0
    if cmd == "import":
        wr(p("uci", rest[0]), sys.stdin.read()); return 0
    return 1

# ------------------------------------------------------------------- wg
def dev_path(dev): return p("wg", dev + ".json")
def dev_load(dev):
    t = rd(dev_path(dev))
    return json.loads(t) if t else None
def dev_save(dev, d): wr(dev_path(dev), json.dumps(d))
def reachable():
    out = {}
    for line in rd(p("net", "reachable")).split():
        pass
    for line in rd(p("net", "reachable")).splitlines():
        f = line.split()
        if f: out[f[0]] = int(f[1]) if len(f) > 1 else 0
    return out
def ep_ip(ep):
    m = re.match(r"^\[(.*)\]:\d+$", ep) or re.match(r"^(.*):\d+$", ep)
    return m.group(1) if m else ep

def wg_main(argv):
    if argv[:1] == ["show"]:
        dev = argv[1]; what = argv[2] if len(argv) > 2 else ""
        d = dev_load(dev)
        if d is None: print(f"Unable to access interface: No such device", file=sys.stderr); return 1
        peer = d.get("peer")
        hs = d.get("hs", 0)
        if d.get("hs_due") and time.time() >= d["hs_due"]:
            hs = int(d["hs_due"]); d["hs"] = hs; d.pop("hs_due"); dev_save(dev, d)
        if what == "public-key": print("PUBKEYOFDEVICExxxxxxxxxxxxxxxxxxxxxxxxxxx="); return 0
        if what == "peers":
            if peer: print(peer)
            return 0
        if what == "latest-handshakes":
            if peer: print(f"{peer}\t{hs}")
            return 0
        if what == "transfer":
            if peer: print(f"{peer}\t1000\t2000")
            return 0
        return 0
    if argv[:1] == ["set"]:
        dev = argv[1]; d = dev_load(dev)
        if d is None: return 1
        a = argv[2:]; i = 0
        while i < len(a):
            k = a[i]
            if k in ("fwmark", "listen-port"): d[k] = a[i+1]; i += 2
            elif k in ("private-key", "preshared-key"):
                f = a[i+1]
                key = rd(f).strip()
                if not key: print("wg: key file missing", file=sys.stderr); return 1
                with open(p("log", "keyfiles"), "a") as kf: kf.write(f + "\n")
                d[k] = "set"; i += 2
            elif k == "peer": d["peer"] = a[i+1]; i += 2
            elif k == "endpoint": d["endpoint"] = a[i+1]; i += 2
            elif k == "persistent-keepalive": d["ka"] = a[i+1]; i += 2
            elif k == "allowed-ips": i += 2
            else: i += 1
        if d.get("peer") and d.get("endpoint") and d.get("ka"):
            r = reachable(); ip = ep_ip(d["endpoint"])
            if ip in r:
                d["hs_due"] = time.time() + r[ip] / 1000.0
        dev_save(dev, d); return 0
    return 1

# ------------------------------------------------------------------- ip
def ip_main(argv):
    fam = "4"
    if argv and argv[0] in ("-4", "-6"): fam = argv[0][1]; argv = argv[1:]
    if argv[:2] == ["link", "add"]:
        dev = argv[argv.index("dev") + 1]
        if dev_load(dev) is not None: print("RTNETLINK answers: File exists", file=sys.stderr); return 2
        dev_save(dev, {"probe": True}); log(f"ip link add {dev}"); return 0
    if argv[:2] == ["link", "del"]:
        dev = argv[argv.index("dev") + 1]
        if dev_load(dev) is None: return 1
        os.remove(dev_path(dev)); log(f"ip link del {dev}"); return 0
    if argv[:2] == ["link", "set"]: return 0
    if argv[:3] == ["route", "show", "default"]:
        sys.stdout.write(rd(p("net", "routes" + fam))); return 0
    if argv[:2] == ["route", "replace"]:
        with open(p("net", "tables"), "a") as f: f.write(fam + " " + " ".join(argv[2:]) + "\n")
        return 0
    if argv[:3] == ["route", "flush", "table"]:
        t = argv[3]
        lines = [l for l in rd(p("net", "tables")).splitlines() if not (l.startswith(fam + " ") and l.endswith(" table " + t))]
        wr(p("net", "tables"), "".join(l + "\n" for l in lines)); return 0
    if argv[:2] == ["rule", "add"]:
        with open(p("net", "rules"), "a") as f: f.write(fam + " " + " ".join(argv[2:]) + "\n")
        return 0
    if argv[:2] == ["rule", "del"]:
        want = fam + " " + " ".join(argv[2:])
        lines = rd(p("net", "rules")).splitlines()
        if want not in lines: return 2
        lines.remove(want); wr(p("net", "rules"), "".join(l + "\n" for l in lines)); return 0
    return 0

# ------------------------------------------------------- ifup / ifdown
def ifup_main(argv):
    iface = argv[0]; log(f"ifup {iface}")
    net = uci_load("network")
    peer = None
    for s, o in net.items():
        if o.get(".type") == f"wireguard_{iface}": peer = o
    d = {"peer": peer["public_key"] if peer else None,
         "endpoint": f"{peer['endpoint_host']}:{peer['endpoint_port']}" if peer else None, "hs": 0}
    r = reachable()
    if peer and peer["endpoint_host"] in r and net.get(iface, {}).get("private_key"):
        d["hs_due"] = time.time() + r[peer["endpoint_host"]] / 1000.0
    dev_save(iface, d); return 0

def ifdown_main(argv):
    iface = argv[0]; log(f"ifdown {iface}")
    if os.path.exists(dev_path(iface)): os.remove(dev_path(iface))
    return 0

# ----------------------------------------------------------------- ping
def ping_main(argv):
    dev = argv[argv.index("-I") + 1] if "-I" in argv else None
    target = argv[-1]
    d = dev_load(dev) if dev else None
    hs = (d or {}).get("hs", 0) or (1 if (d or {}).get("hs_due") and time.time() >= d["hs_due"] else 0)
    ok = d is not None and d.get("endpoint") and ep_ip(d["endpoint"]) in reachable() and hs > 0
    print(f"PING {target} ({target}): 56 data bytes")
    if ok:
        print(f"--- {target} ping statistics ---\n3 packets transmitted, 3 packets received, 0% packet loss")
        print("round-trip min/avg/max = 20.1/23.4/30.2 ms"); return 0
    print(f"--- {target} ping statistics ---\n3 packets transmitted, 0 packets received, 100% packet loss"); return 1

def nslookup_main(argv):
    host = argv[0]
    m = dict(l.split() for l in rd(p("net", "dns")).splitlines() if l.strip())
    if host in m:
        print(f"Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\nName:\t{host}\nAddress: {m[host]}"); return 0
    print(f"** server can't find {host}: NXDOMAIN"); return 1

def main():
    tool = os.path.basename(sys.argv[0]); argv = sys.argv[1:]
    if tool == "uci": return uci_main(argv)
    if tool == "wg": return wg_main(argv)
    if tool == "ip": return ip_main(argv)
    if tool == "ifup": return ifup_main(argv)
    if tool == "ifdown": return ifdown_main(argv)
    if tool == "ping": return ping_main(argv)
    if tool == "nslookup": return nslookup_main(argv)
    if tool == "logger":
        msg = " ".join(a for a in argv if not a.startswith("-") and a not in ("wgswitch",) )
        with open(p("log", "syslog"), "a") as f: f.write(" ".join(argv) + "\n")
        return 0
    if tool == "usleep": time.sleep(int(argv[0]) / 1e6); return 0
    if tool == "id": print("0"); return 0
    print(f"fake.py: unknown tool {tool}", file=sys.stderr); return 127

sys.exit(main())
