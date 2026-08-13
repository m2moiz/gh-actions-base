# gh-actions-base

A base GitHub Actions setup to start projects from. Nine workflows, every action
pinned to a commit hash, and the one piece most CI templates leave out: a script
that makes the checks **binding** instead of advisory.

Validated with `actionlint` (clean) and `zizmor` (**0 high, 0 medium, 0 low**;
one informational, noted below).

## Use it

```bash
gh repo create my-project --template m2moiz/gh-actions-base --private --clone
cd my-project
git push                       # let ci run once so the check names register
./.github/bootstrap.sh         # NOW the checks become required
```

The order matters. GitHub can only require a status check it has seen report at
least once, so `bootstrap.sh` after the first run, not before.

## What runs when

| Workflow | Trigger | Jobs |
|---|---|---|
| `ci.yml` | push to main, PR | super-linter · typos · test matrix + coverage |
| `security.yml` | push, PR, weekly | trufflehog · owasp noir |
| `pr.yml` | pull request | pr-agent · lost-pixel · automerge |
| `release.yml` | push to main | tag bump → gh-release |
| `scheduled.yml` | daily | linkcheck · metrics embed |
| `codeql.yml` | push, PR, weekly | SAST over python + actions |
| `posture.yml` | push, PR, weekly | zizmor · actionlint · scorecard |
| `review.yml` | PR, `@claude` / `@codex` | two-family adversarial review |

## The design decisions worth knowing

**`permissions: {}` at the top of every file.** Jobs elevate only what they
need. Without it the token carries the repository default, which is usually
write — the thing Scorecard's `Token-Permissions` check exists to catch.

**Everything pinned to a SHA, with the tag in a trailing comment.** A tag can be
moved by whoever owns the action; a hash cannot. This is what takes zizmor's
`unpinned-uses` findings from 24 to 0 — and it is why `dependabot.yml` is not
optional, because pins rot silently and a pinned action never picks up a
security fix on its own.

**`pull_request`, never `pull_request_target`.** The latter would hand fork PRs
write access and your secrets. Combined with a checkout of the PR head it is the
most exploited Actions misconfiguration there is, and both zizmor and Scorecard
flag it. The cost is that fork PRs get no secrets, so every job that needs one
checks it is present and **skips cleanly** rather than failing — otherwise the
template makes every outside contribution look broken.

**A skipped test fails the build.** `ci.yml` greps the pytest summary and errors
on `skipped`. A skip and a pass are identical in an exit code, and a `skipif` on
the very condition a gate exists to detect will report green in exactly the
broken state.

**The test matrix spans the interpreter range the package declares.** A
single-version CI is how a project claims support for versions nobody has run.

**`uv lock --check`.** Fails when `pyproject.toml` and `uv.lock` disagree — a
hand-run `uv lock` nobody committed is otherwise invisible until someone else
installs.

**Release is two jobs in one workflow, not a `push: tags` trigger.** Tags pushed
by `GITHUB_TOKEN` deliberately do not trigger further workflow runs, so a
tag-triggered release workflow never fires. The tag job hands its output to the
release job instead.

## Configuration

Everything below is optional; each job skips cleanly when its value is absent.

| Secret | Used by | Without it |
|---|---|---|
| `CODECOV_TOKEN` | codecov | tokenless upload, rate-limited and flaky |
| `OPENAI_KEY` | pr-agent | review job skips |
| `METRICS_TOKEN` | metrics embed | metrics job skips (needs a classic PAT) |
| `LOST_PIXEL_API_KEY` | lost-pixel | only used when opted in |
| `ANTHROPIC_API_KEY` | claude review | that reviewer skips |
| `OPENAI_API_KEY` | codex review | that reviewer skips |

| Variable | Used by |
|---|---|
| `LINKCHECK_URL` | linkcheck; unset means the job skips |

| Label | Effect |
|---|---|
| `visual-regression` | opts a PR into lost-pixel |
| `automerge` | opts a PR into automerge |

## Why two AI reviewers and not one

Running Claude and Codex on the same diff looks like redundancy. It isn't. In
the session that produced this template, four independent review lanes from one
model family — run blind, in parallel, with different checklists — all missed a
defect that a single reviewer from a *different* family found immediately: an
evaluation question set that leaked its own answers, invalidating the experiment
built on top of it.

Same-family reviewers share blind spots, so their agreement is correlation
rather than evidence. The two jobs therefore get **deliberately different
prompts** — one hunts failure scenarios in the code, the other hunts assumptions
the author never checked. Where they agree you learn little; where they differ,
one of them has seen something.

Both skip cleanly without their key, so fork PRs are unaffected.

## Two honest caveats

**`pascalgn/automerge-action` was last pushed 2024-09-22.** It works and it is
included because it was asked for. `bootstrap.sh` also enables GitHub's native
auto-merge, which does the same job with nothing to maintain — prefer
`gh pr merge --auto --squash` if you ever want one less dependency.

**zizmor reports one informational finding**, that `softprops/action-gh-release`
duplicates what `gh release create` can do in a script step. True, and the
action is kept anyway: it is a deliberate choice, not an oversight.

## Adapting it

The three places that need a look in a new project:

1. `ci.yml` — the `python` matrix, and the test command if you are not on
   pytest.
2. `pr.yml` — the lost-pixel job assumes a storybook build. Delete it if the
   project has no UI.
3. `bootstrap.sh` — the required-check list must match the `name:` fields in
   `ci.yml`. A required check that never reports blocks every merge forever;
   a name that silently stops matching blocks nothing at all.
