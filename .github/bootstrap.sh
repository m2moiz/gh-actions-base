#!/usr/bin/env bash
# bootstrap.sh — turn the workflows in this repo from advisory into binding.
#
# THIS IS THE FILE THAT MATTERS. A workflow that is not a REQUIRED status check
# is a suggestion: a red pull request merges exactly as easily as a green one,
# and the only thing standing between you and a broken main branch is whoever
# remembered to look. Branch protection is not a workflow file and cannot ship
# inside `.github/workflows/`, which is why every "all-in-one CI template" you
# will find stops short of this.
#
# Run once per repository, after the first CI run has registered the check
# names with GitHub:
#
#     ./.github/bootstrap.sh                 # current repo, inferred from git
#     ./.github/bootstrap.sh owner/name      # explicit
#
# Idempotent: re-running updates the existing ruleset rather than adding a
# second one.

set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
RULESET_NAME="base-protection"

echo "==> target: $REPO"

# The job NAMES from ci.yml, which is what GitHub registers as check runs --
# not the workflow name and not the job id. Keep this list and ci.yml in step;
# a required check that never reports blocks every merge forever, and a check
# name that silently stops matching blocks nothing at all.
read -r -d '' CHECKS <<'JSON' || true
[
  {"context": "super-linter"},
  {"context": "typos"},
  {"context": "test (py3.12)"},
  {"context": "test (py3.13)"},
  {"context": "trufflehog"}
]
JSON

existing=$(gh api "repos/$REPO/rulesets" --jq \
  ".[] | select(.name == \"$RULESET_NAME\") | .id" 2>/dev/null || true)

payload=$(
  python3 - "$CHECKS" <<'PY'
import json, sys
checks = json.loads(sys.argv[1])
print(json.dumps({
    "name": "base-protection",
    "target": "branch",
    "enforcement": "active",
    "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
    "rules": [
        # No direct pushes: everything arrives through a pull request, where the
        # checks below can actually gate it.
        {"type": "pull_request", "parameters": {
            "required_approving_review_count": 0,
            "dismiss_stale_reviews_on_push": False,
            "require_code_owner_review": False,
            "require_last_push_approval": False,
            "required_review_thread_resolution": False,
        }},
        {"type": "required_status_checks", "parameters": {
            "required_status_checks": checks,
            # A PR that has not seen the current main has not been tested
            # against it -- including against a gate main added yesterday.
            "strict_required_status_checks_policy": True,
        }},
        {"type": "non_fast_forward"},   # no force-push
        {"type": "deletion"},           # main cannot be deleted
    ],
}))
PY
)

if [ -n "$existing" ]; then
  echo "==> updating ruleset $existing"
  gh api -X PUT "repos/$REPO/rulesets/$existing" --input - <<<"$payload" >/dev/null
else
  echo "==> creating ruleset"
  gh api -X POST "repos/$REPO/rulesets" --input - <<<"$payload" >/dev/null
fi

# Auto-merge is the point of the whole exercise. With it on you stop watching
# CI and merging by hand -- `gh pr merge --auto --squash` hands the decision to
# GitHub, which merges when the required checks pass and not before. That
# deletes a class of human error rather than asking anyone to be careful.
echo "==> enabling auto-merge and branch cleanup"
gh api -X PATCH "repos/$REPO" \
  -F allow_auto_merge=true \
  -F delete_branch_on_merge=true \
  -F allow_merge_commit=false \
  -F allow_rebase_merge=false >/dev/null

# Repository settings the workflows depend on but cannot switch on themselves.
# dependency-review fails outright with "Dependency review is not supported on
# this repository" until the graph is enabled -- observed on the first live run
# of this template, on a repo created minutes earlier.
echo "==> enabling dependency graph, alerts and security updates"
gh api -X PATCH "repos/$REPO" \
  -f 'security_and_analysis[dependency_graph][status]=enabled' >/dev/null 2>&1 || true
# Order matters: alerts are a precondition for automated fixes, and enabling
# the second first returns 422.
gh api -X PUT "repos/$REPO/vulnerability-alerts" >/dev/null
gh api -X PUT "repos/$REPO/automated-security-fixes" >/dev/null

cat <<EOF

Done. main on $REPO now requires:
  - a pull request
  - green: super-linter, typos, test (py3.12), test (py3.13), trufflehog
  - the branch to be up to date with main
  - no force-pushes, no deletion

From here, merge with:  gh pr merge --auto --squash

If a required check never reports, it is almost always a NAME mismatch between
the list at the top of this script and the \`name:\` fields in ci.yml.
EOF
