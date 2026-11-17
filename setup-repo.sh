#!/bin/sh
# =============================================================================
# setup-repo.sh - one-time setup of github.com/mateusrdp/openwrt-wgswitch
#
# Run it from this folder, on your own computer (Linux/macOS), once:
#   sh setup-repo.sh
#
# Needs: git, gh (logged in: `gh auth login`), openssl.
#
# What it does (each step is skipped if already done, so it's safe to re-run):
#   1. git init (branch main) + installs the pre-commit secret guard
#   2. creates the apk signing key OUTSIDE the repo, in
#      ~/.config/openwrt-wgswitch/signing-key.pem (back this file up!)
#      and puts only the PUBLIC key in keys/wgswitch.pem
#   3. creates the public GitHub repo and sets the remote
#   4. stores the private signing key as the repo secret APK_SIGN_KEY
#   5. enables GitHub Pages (deployed by the workflow, for the apk feed)
#   6. scans everything for secrets, commits and pushes
#
# Nothing here ever uploads a WireGuard config or a private key to GitHub:
# the signing key only ever goes to GitHub's encrypted secret store.
# =============================================================================
set -eu
REPO="${REPO:-mateusrdp/openwrt-wgswitch}"
KEY_DIR="${KEY_DIR:-$HOME/.config/openwrt-wgswitch}"
KEY="$KEY_DIR/signing-key.pem"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

cd "$(dirname "$0")"
[ -f wgswitch/Makefile ] && [ -f scripts/check-secrets.sh ] || die "run this from the openwrt-wgswitch folder"
for c in git gh openssl; do command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"; done
gh auth status >/dev/null 2>&1 || die "gh is not logged in - run: gh auth login"

say "1/6 git repository + secret guard"
[ -d .git ] || git init -q -b main
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit scripts/*.sh tests/*.sh wgswitch/files/wgswitch wgswitch/files/wgswitch.init
echo "pre-commit hook active: commits containing keys or .conf files are refused"

say "2/6 apk signing key"
if [ -f "$KEY" ]; then
    echo "using existing $KEY"
else
    mkdir -p "$KEY_DIR"; chmod 700 "$KEY_DIR"
    ( umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$KEY" )
    echo "created $KEY - BACK IT UP. Losing it means re-keying every router that uses the feed."
fi
mkdir -p keys
openssl ec -in "$KEY" -pubout -out keys/wgswitch.pem 2>/dev/null
grep -q 'BEGIN PUBLIC KEY' keys/wgswitch.pem || die "public key export failed"
case "$(cd "$(dirname "$KEY")" && pwd)" in "$(pwd)"*) die "signing key must not live inside the repo" ;; esac

say "3/6 GitHub repository $REPO"
if gh repo view "$REPO" >/dev/null 2>&1; then
    echo "repo exists"
else
    gh repo create "$REPO" --public \
        --description "WireGuard client profile switcher for OpenWrt: handshake-tested server selection, health checks, kill switch, LuCI page" >/dev/null
    echo "created https://github.com/$REPO"
fi
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"
gh auth setup-git >/dev/null 2>&1 || true   # lets `git push` use gh's login

say "4/6 repo secret APK_SIGN_KEY"
gh secret set APK_SIGN_KEY --repo "$REPO" < "$KEY"

say "5/6 GitHub Pages (deployed by the workflow)"
if gh api "repos/$REPO/pages" >/dev/null 2>&1; then
    gh api -X PUT "repos/$REPO/pages" -f build_type=workflow >/dev/null 2>&1 || true
else
    gh api -X POST "repos/$REPO/pages" -f build_type=workflow >/dev/null
fi
# The feed is deployed from v* tags; GitHub's github-pages environment only
# allows the default branch unless told otherwise.
gh api -X PUT "repos/$REPO/environments/github-pages" --input - >/dev/null <<'JSON'
{ "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
JSON
gh api -X POST "repos/$REPO/environments/github-pages/deployment-branch-policies" -f name='v*' -f type=tag >/dev/null 2>&1 || true
gh api -X POST "repos/$REPO/environments/github-pages/deployment-branch-policies" -f name=main -f type=branch >/dev/null 2>&1 || true
echo "Pages source: GitHub Actions, deployable from main and v* tags"

say "6/6 secret scan, commit, push"
git add -A
sh scripts/check-secrets.sh --staged
if git diff --cached --quiet; then
    echo "nothing new to commit"
else
    git commit -q -m "Initial import: wgswitch + luci-app-wgswitch

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
fi
sh scripts/check-secrets.sh --history
git push -u origin main

cat <<EOF

Done. https://github.com/$REPO

Every push runs the checks, the real-WireGuard test and an .apk build
(Actions tab). To publish a release + the signed apk feed:

    git tag v0.1.0 && git push origin v0.1.0

Then on the router (once):

    wget -O /etc/apk/keys/wgswitch.pem https://${REPO%%/*}.github.io/${REPO#*/}/wgswitch.pem
    echo 'https://${REPO%%/*}.github.io/${REPO#*/}/packages.adb' > /etc/apk/repositories.d/wgswitch.list
    apk update && apk add wgswitch luci-app-wgswitch

Keep $KEY backed up and private.
EOF
