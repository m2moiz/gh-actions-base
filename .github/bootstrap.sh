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

# REFUSE TO SILENTLY REPLACE SOMEONE ELSE'S CHECK LIST. "Idempotent: re-running
# updates the existing ruleset" is true and was the trap: this script carries
# the TEMPLATE's check names, so running it from a template clone against a
# real project overwrote that project's required checks with names its CI never
# reports -- which does not fail loudly, it just blocks every future merge on
# checks that will never arrive. Observed the first time it was pointed at a
# second repository.
if [ -n "$existing" ]; then
  current=$(gh api "repos/$REPO/rulesets/$existing" --jq \
    '[.rules[] | select(.type == "required_status_checks")
      | .parameters.required_status_checks[].context] | sort | join(",")' 2>/dev/null || true)
  wanted=$(python3 -c 'import json,sys; print(",".join(sorted(c["context"] for c in json.loads(sys.argv[1]))))' "$CHECKS")
  if [ -n "$current" ] && [ "$current" != "$wanted" ]; then
    cat >&2 <<EOF
REFUSING to overwrite the existing "$RULESET_NAME" ruleset on $REPO.

  it currently requires: $current
  this script would set: $wanted

Those differ, which usually means you are running a copy of this script that
still carries another project's check names. Edit CHECKS at the top of this
file to match this repository's job names, then re-run.

If the change is what you actually want:  BOOTSTRAP_FORCE=1 $0 $REPO
EOF
    [ "${BOOTSTRAP_FORCE:-0}" = "1" ] || exit 1
    echo "==> BOOTSTRAP_FORCE=1, overwriting anyway" >&2
  fi
fi

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

# Report what the SERVER says is in force, not what this script intended. The
# closing message used to hardcode the template's own check names, so pointing
# the script at another repository with a different CHECKS list printed a
# confident and entirely wrong summary -- observed the first time it was run
# against a real project. A bootstrap that misreports what it just configured
# is worse than a silent one.
applied=$(gh api "repos/$REPO/rules/branches/$(gh api "repos/$REPO" --jq .default_branch)" \
  --jq '[.[] | select(.type == "required_status_checks")
         | .parameters.required_status_checks[].context] | join(", ")')

cat <<EOF

Done. The default branch on $REPO now requires:
  - a pull request
  - green: ${applied:-<none reported -- check the ruleset>}
  - the branch to be up to date with it
  - no force-pushes, no deletion

From here, merge with:  gh pr merge --auto --squash

If a required check never reports, it is almost always a NAME mismatch between
the list at the top of this script and the \`name:\` fields in ci.yml.
EOF
