#!/bin/sh
# =============================================================================
# setup-claude.sh - configure github.com/mateusrdp/openwrt-wgswitch so Claude
# can develop in it safely. Run on your own computer, from this folder:
#
#   sh setup-claude.sh
#
# Needs: git, gh (logged in, as the repo owner). Safe to re-run.
#
#   1. creates the repo first if it doesn't exist yet (runs setup-repo.sh)
#   2. commits + pushes any repo files not on GitHub yet (secret-scanned)
#   3. merge settings: squash only, delete branches after merge, auto-merge
#   4. main is protected: changes only via pull request, and only when the
#      CI jobs (checks, integration, build) pass. No force-push, no deletion.
#      You stay able to merge; Claude opens PRs and never merges them.
#   5. GitHub's own secret scanning + push protection switched on - a second
#      wall behind the repo's pre-commit hook and CI scan
#   6. Actions: read-only token by default, can't approve PRs
#   7. Pages environment allows deploys from v* tags (the feed is
#      published from tags; GitHub's default only allows main)
#   8. opens the page to install the Claude GitHub App on THIS repo only
#
# What Claude gets inside the repo (committed, see .claude/settings.json):
#   - a SessionStart hook running scripts/dev-setup.sh, which activates the
#     secret-guard pre-commit hook (git does not clone that setting)
#   - allowed: tests, linters, git commit/push to branches, opening PRs
#   - denied: reading *.conf/*.key/.env, --no-verify, force-push, merging
#     PRs, tags/releases, touching repo secrets
# =============================================================================
set -eu
REPO="${REPO:-mateusrdp/openwrt-wgswitch}"
CHECKS='["checks", "integration", "build"]'

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
api() { gh api -H "Accept: application/vnd.github+json" "$@"; }

cd "$(dirname "$0")"
[ -f wgswitch/Makefile ] && [ -f .claude/settings.json ] || die "run this from the openwrt-wgswitch folder (with .claude/settings.json in it)"
for c in git gh; do command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"; done
gh auth status >/dev/null 2>&1 || die "gh is not logged in - run: gh auth login"

say "1/8 repository"
if ! gh repo view "$REPO" >/dev/null 2>&1; then
    echo "repo doesn't exist yet - running setup-repo.sh first"
    sh ./setup-repo.sh
elif [ ! -d .git ]; then
    die "$REPO already exists, but this folder isn't a clone of it. Run:
    gh repo clone $REPO ~/openwrt-wgswitch-git
    cp -r .claude .github scripts setup-claude.sh CLAUDE.md ~/openwrt-wgswitch-git/
    cd ~/openwrt-wgswitch-git && sh setup-claude.sh"
fi
sh scripts/dev-setup.sh

say "2/8 push local files that aren't on GitHub yet"
git add -A
if git diff --cached --quiet; then
    echo "nothing new"
else
    sh scripts/check-secrets.sh --staged
    MSG="Development setup for Claude: session hook, permissions, dependabot

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
    if api "repos/$REPO/branches/main/protection" >/dev/null 2>&1; then
        # main is already protected (re-run): go through a pull request
        BR="dev-setup-$(date +%Y%m%d%H%M%S)"
        git switch -q -c "$BR"
        git commit -q -m "$MSG"
        git push -q -u origin "$BR"
        gh pr create --repo "$REPO" --base main --head "$BR" \
            --title "Development setup for Claude" --body "Session hook, permissions, dependabot. Created by setup-claude.sh."
        git switch -q main
        echo "opened a pull request - merge it once CI is green"
    else
        git commit -q -m "$MSG"
        git push -q origin main
        echo "pushed to main"
    fi
fi

say "3/8 merge settings"
api -X PATCH "repos/$REPO" \
    -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
    -F delete_branch_on_merge=true -F allow_auto_merge=true -F allow_update_branch=true \
    -F has_wiki=false -F has_projects=false >/dev/null
echo "squash merges only, branches deleted after merge"

say "4/8 protect main"
api -X PUT "repos/$REPO/branches/main/protection" --input - >/dev/null <<EOF
{
  "required_status_checks": { "strict": true, "contexts": $CHECKS },
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 0, "dismiss_stale_reviews": true },
  "restrictions": null,
  "required_linear_history": true,
  "required_conversation_resolution": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
echo "main: pull requests only, CI ($CHECKS) must pass, no force-push/deletion"
echo "(you, as admin, can still push directly in an emergency)"

say "5/8 GitHub secret scanning + push protection"
if api -X PATCH "repos/$REPO" --input - >/dev/null 2>&1 <<'EOF'
{ "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" } } }
EOF
then echo "enabled"; else echo "could not enable (do it in Settings > Code security) - continuing"; fi

say "6/8 Actions token permissions"
api -X PUT "repos/$REPO/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false >/dev/null
echo "default GITHUB_TOKEN: read-only; jobs that need more ask for it explicitly"

say "7/8 Pages: allow deploys from release tags"
api -X POST "repos/$REPO/pages" -f build_type=workflow >/dev/null 2>&1 \
    || api -X PUT "repos/$REPO/pages" -f build_type=workflow >/dev/null 2>&1 || true
api -X PUT "repos/$REPO/environments/github-pages" --input - >/dev/null <<'EOF'
{ "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
EOF
api -X POST "repos/$REPO/environments/github-pages/deployment-branch-policies" -f name='v*' -f type=tag >/dev/null 2>&1 || true
api -X POST "repos/$REPO/environments/github-pages/deployment-branch-policies" -f name=main -f type=branch >/dev/null 2>&1 || true
echo "github-pages environment: main + v* tags"

say "8/8 Claude GitHub App"
URL="https://github.com/apps/claude/installations/new"
echo "Install it for THIS repository only (choose 'Only select repositories'):"
echo "  $URL"
( command -v xdg-open >/dev/null 2>&1 && xdg-open "$URL" ) >/dev/null 2>&1 \
    || ( command -v open >/dev/null 2>&1 && open "$URL" ) >/dev/null 2>&1 || true

cat <<EOF

Done. Summary of how work flows from here:
  - Claude works on a branch, runs the tests, pushes, opens a PR
  - CI must pass (secret scan over all history, shellcheck, tests,
    real-WireGuard test, SDK build) before the PR can merge
  - you review and merge; releases stay yours: git tag vX.Y.Z && git push origin vX.Y.Z

Then tell Claude: "the repo is ready" - it attaches $REPO to the session.
EOF
