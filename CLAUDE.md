# CLAUDE.md - working in openwrt-wgswitch

## Hard rules

1. **Never commit WireGuard configs, keys or credentials.** No `.conf`
   files, no real or realistic-looking keys (44-char base64 ending `=`), no
   tokens. Docs use placeholders (`<your-private-key>`). Tests generate keys
   at run time from `/dev/urandom`. `scripts/check-secrets.sh` enforces this
   (pre-commit hook + CI over the whole history). If it blocks something,
   remove the secret; never weaken the scanner or bypass the hook.
2. **Generic package.** Nothing specific to one person's network
   (addresses, interface names, topology) goes in this repo. Site specifics
   belong in uci options or the `hook`.
3. **POSIX sh for BusyBox ash.** No bashisms, no `local`; function-private
   variables are prefixed `_fn_`. `shellcheck -s sh` must be clean.
4. **Never call `profile_load` (or anything that sets `P_*`) inside
   `$(...)`.** The subshell loses the variables. This bug existed once and
   sent connects out with an empty endpoint.
5. **Secrets never reach stdout, stderr or syslog.** Keys go to `wg` only
   through 0600 files under `$WGS_RUN` (tmpfs), removed immediately.
6. **Anything that changes live state holds the `main` lock; the probe
   holds `probe`.** A failed connect must restore the previous state
   (`uci export/import network`).

## How work flows

- `scripts/dev-setup.sh` runs at session start (SessionStart hook). It
  activates the pre-commit secret guard, which a fresh clone does not have.
  If it reports the hook as NOT-ACTIVE, stop and fix that before committing.
- Work on a branch, never on `main` (it's protected). Run the checks below,
  push the branch, open a PR with `gh pr create`. CI must pass.
- **Never merge PRs, create tags or releases, or touch repo secrets.** The
  owner merges and releases. `.claude/settings.json` denies these too.
- Never read `.conf`, `.key` or `.env` files, even if one turns up in the
  working tree. Tell the owner instead.

## Layout

```
wgswitch/Makefile                 OpenWrt package (PKGARCH:=all)
wgswitch/files/wgswitch           CLI + daemon (sources lib.sh)
wgswitch/files/lib.sh             parsing, validation, netifd, health, probe, results
wgswitch/files/wgswitch.init      procd service (`wgswitch daemon`)
wgswitch/files/wgswitch.config    /etc/config/wgswitch defaults
luci-app-wgswitch/                LuCI JS view (Network > VPN), menu.d, acl.d
tests/run.sh                      flow tests: BusyBox ash + tests/shims/fake.py
tests/integration.sh              real kernel WireGuard in netns (root, CI)
scripts/check-secrets.sh          secret guard
setup-repo.sh                     one-time GitHub setup (signing key, Pages)
setup-claude.sh                   branch protection, secret scanning, Claude app
scripts/dev-setup.sh              per-clone setup (hook, tools); runs at session start
.claude/settings.json             Claude Code session hook + permissions
```

## Before every commit

```sh
shellcheck -s sh -x -P wgswitch/files wgswitch/files/wgswitch wgswitch/files/lib.sh
sh tests/run.sh -v
sh scripts/check-secrets.sh --all
```

New behaviour gets a test in `tests/run.sh`. Extend `tests/shims/fake.py`
when a new external command is used. Keep README.md in step with the code.

## Design notes

- One live interface; switching rewrites it. The probe uses one temporary
  interface that is never in uci, plus fwmark rules (`probe_rules`) so its
  packets avoid the live tunnel.
- LuCI never runs long operations directly. It uses `--bg`, which queues
  the job in `$WGS_RUN/queue` for the daemon, because rpcd's exec timeout
  would otherwise cut a connect off halfway.
- Release: bump `PKG_VERSION` in both Makefiles, tag `vX.Y.Z`, push the
  tag. CI builds, signs the index with the `APK_SIGN_KEY` secret, and
  publishes the GitHub Release + the Pages feed.
