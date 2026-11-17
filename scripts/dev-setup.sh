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
#   2. makes sure the tools the checks need are present
#      (busybox, shellcheck, jq, node, python3), installing via apt if possible
#   3. prints what's missing, if anything
# =============================================================================
cd "$(git rev-parse --show-toplevel 2>/dev/null || dirname "$0")" || exit 0

git config core.hooksPath .githooks 2>/dev/null
chmod +x .githooks/pre-commit scripts/*.sh tests/*.sh tests/shims/fake.py \
    wgswitch/files/wgswitch wgswitch/files/wgswitch.init 2>/dev/null

need=
for t in busybox shellcheck jq; do command -v "$t" >/dev/null 2>&1 || need="$need $t"; done
if [ -n "$need" ] && command -v apt-get >/dev/null 2>&1; then
    SUDO=; [ "$(id -u)" = 0 ] || SUDO=sudo
    # shellcheck disable=SC2086  # $need is a word list on purpose
    { $SUDO apt-get install -y -q $need || { $SUDO apt-get update -q && $SUDO apt-get install -y -q $need; }; } >/dev/null 2>&1
fi

missing=
for t in busybox shellcheck jq node python3; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
if [ "$(git config core.hooksPath)" = .githooks ]; then hook=active; else hook=NOT-ACTIVE; fi
echo "dev-setup: secret-guard hook $hook${missing:+; missing tools:$missing}"
exit 0
