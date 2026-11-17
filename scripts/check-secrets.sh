#!/bin/sh
# =============================================================================
# check-secrets.sh - refuse to let WireGuard configs or credentials into git.
#
#   sh scripts/check-secrets.sh --staged    # pre-commit: what's about to be committed
#   sh scripts/check-secrets.sh --all       # every tracked file
#   sh scripts/check-secrets.sh --history   # every commit ever (CI)
#   sh scripts/check-secrets.sh FILE...     # specific files
#
# Blocks:
#   * *.conf files, private keys (*.key, *private*.pem), .env files
#   * anything that looks like a WireGuard key (44-char base64 ending '=')
#   * "PrivateKey =" / "PresharedKey =" lines with a value
#   * PEM private key blocks, GitHub tokens
# Documentation must use placeholders such as <your-private-key>.
# Exit 1 on any finding.
# =============================================================================
set -u
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

# A WireGuard key as a standalone token: 44 base64 chars, not part of a
# longer base64 run (PEM lines, hashes) - that caused false positives.
WG_KEY='(^|[^A-Za-z0-9+/])[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=($|[^A-Za-z0-9+/=])'
CONTENT_RE="($WG_KEY)|((PrivateKey|PresharedKey)[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{8,})|(-----BEGIN ([A-Z]+ )?PRIVATE KEY-----)|(gh[pousr]_[A-Za-z0-9]{30,})"
# Files that may contain these patterns *as patterns* (this scanner and the
# validator's regex), not as values.
ALLOW_CONTENT='^(scripts/check-secrets\.sh|wgswitch/files/lib\.sh|\.githooks/pre-commit)$'

found=0
report() { echo "BLOCKED: $1" >&2; found=1; }

check_name() {
    case "$1" in
        *.conf|*.key|*private*.pem|*.env|.env*|*id_rsa*|*id_ed25519*) report "$1 - file type is never allowed in this repo" ;;
    esac
}
check_content() {  # check_content <label> < content ; returns 1 on a finding
    _cc_tmp="${TMPDIR:-/tmp}/secrets.$$.$(date +%N 2>/dev/null)"
    # The feed's PUBLIC signing key is meant to be published. Allow it only
    # if it is nothing but one public key block.
    case "$1" in
        keys/wgswitch.pem*)
            cat > "$_cc_tmp"
            if grep -q 'PRIVATE' "$_cc_tmp" \
                || [ "$(grep -c -- '-----BEGIN PUBLIC KEY-----' "$_cc_tmp")" != 1 ] \
                || grep -vqE '^(-----(BEGIN|END) PUBLIC KEY-----|[A-Za-z0-9+/=]{1,76})$' "$_cc_tmp"; then
                echo "BLOCKED: $1 - must contain exactly one PUBLIC key and nothing else" >&2
                rm -f "$_cc_tmp"; return 1
            fi
            rm -f "$_cc_tmp"; return 0 ;;
    esac
    if grep -nE "$CONTENT_RE" > "$_cc_tmp" 2>/dev/null; then
        echo "BLOCKED: $1 - contains something that looks like a key or credential:" >&2
        sed 's/\([A-Za-z0-9+\/]\{6\}\)[A-Za-z0-9+\/=]*/\1…(redacted)/g' "$_cc_tmp" | head -n 5 | sed 's/^/    /' >&2
        rm -f "$_cc_tmp"; return 1
    fi
    rm -f "$_cc_tmp"; return 0
}

case "${1:-}" in
    --staged)
        git diff --cached --name-only --diff-filter=ACMR | while IFS= read -r f; do
            check_name "$f"
            printf '%s' "$f" | grep -Eq "$ALLOW_CONTENT" && continue
            git show ":$f" 2>/dev/null | check_content "$f" || found=1
            [ "$found" = 0 ] || exit 1
        done || found=1
        ;;
    --all)
        for f in $(git ls-files); do
            check_name "$f"
            printf '%s' "$f" | grep -Eq "$ALLOW_CONTENT" && continue
            # shellcheck disable=SC2094
            check_content "$f" < "$f" || found=1
        done
        ;;
    --history)
        for f in $(git log --all --pretty=format: --name-only | sort -u); do check_name "$f"; done
        for c in $(git rev-list --all); do
            for f in $(git diff-tree --no-commit-id --name-only -r --root "$c"); do
                printf '%s' "$f" | grep -Eq "$ALLOW_CONTENT" && continue
                git show "$c:$f" 2>/dev/null | check_content "$f (commit $(printf '%s' "$c" | cut -c1-8))" || found=1
            done
        done
        ;;
    "") echo "usage: $0 --staged | --all | --history | FILE..." >&2; exit 2 ;;
    *)
        # shellcheck disable=SC2094
        for f in "$@"; do check_name "$f"; check_content "$f" < "$f" || found=1; done
        ;;
esac

if [ "$found" != 0 ]; then
    echo "" >&2
    echo "Refusing: WireGuard configs, keys and credentials must never be in this repository." >&2
    echo "Use placeholders like <your-private-key> in docs; tests generate keys at run time." >&2
    exit 1
fi
exit 0
