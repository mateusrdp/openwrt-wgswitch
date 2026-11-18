#!/bin/sh
# =============================================================================
# dev-setup.sh - prepare a working copy for development (humans and Claude).
#
# Run automatically at the start of every Claude Code session (SessionStart
# hook in .claude/settings.json); run it by hand after any fresh clone.
# Idempotent, never fails the session: missing tools are reported, not fatal.
#
#   1. activates the secret-guard pre-commit hook. core.hooksPath is
#      per-clone git config, so a fresh clone does NOT have it until this runs
#   2. checks for the tools the checks need (busybox, shellcheck, jq, node,
#      python3). It installs missing ones with apt ONLY when already running
#      as root (e.g. a disposable sandbox). It never uses sudo: on your own
#      machine it just prints the install command.
# =============================================================================
cd "$(git rev-parse --show-toplevel 2>/dev/null || dirname "$0")" || exit 0

git config core.hooksPath .githooks 2>/dev/null
chmod +x .githooks/pre-commit scripts/*.sh tests/*.sh tests/shims/fake.py \
    wgswitch/files/wgswitch wgswitch/files/wgswitch.init 2>/dev/null

need=
for t in busybox shellcheck jq; do command -v "$t" >/dev/null 2>&1 || need="$need $t"; done
if [ -n "$need" ] && [ "$(id -u)" = 0 ] && command -v apt-get >/dev/null 2>&1; then
    # shellcheck disable=SC2086  # $need is a word list on purpose
    { apt-get install -y -q $need || { apt-get update -q && apt-get install -y -q $need; }; } >/dev/null 2>&1
fi

missing=
for t in busybox shellcheck jq node python3; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
if [ "$(git config core.hooksPath)" = .githooks ]; then hook=active; else hook=NOT-ACTIVE; fi
echo "dev-setup: secret-guard hook $hook"
if [ -n "$missing" ]; then
    echo "dev-setup: missing tools for the local checks:$missing"
    pkgs=$(printf '%s' "$missing" | sed 's/ node/ nodejs/')
    echo "           install them yourself if you want to run the checks locally, e.g.: sudo apt install$pkgs"
fi
exit 0
