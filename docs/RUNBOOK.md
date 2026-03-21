# CI Workflows Runbook

## Break-Glass: Roll back @v1

When a broken reusable workflow is deployed to @v1 and blocking consumer repos:

1. Identify last known-good SHA: `git log --oneline --tags`
2. Force-update tag: `git tag -f v1 <sha> && git push --force-with-lease origin v1`
3. Verify: open a test PR on any consumer repo, confirm CI passes
4. Root-cause the broken workflow, fix, tag new point release, re-tag @v1

## Secret Rotation

When API keys, OAuth tokens, or other secrets need updating:

1. Update values in `~/.env`
2. Run: `scripts/ci-sweep.sh --secrets --all`
3. Verify per repo: `gh secret list --repo parthalon025/<repo>`

### Required Secrets by Tier

| Secret | Tier 1 | Tier 2 | Tier 3 |
|--------|--------|--------|--------|
| GITHUB_TOKEN | auto | auto | auto |
| CODECOV_TOKEN | yes | no | no |
| TS_OAUTH_CLIENT_ID | deploy repos only | no | no |
| TS_OAUTH_SECRET | deploy repos only | no | no |
| ANTHROPIC_API_KEY | yes (claude-review) | no | no |

## Adding a New Repo

1. Add row to `docs/TIER-ASSIGNMENTS.md` (repo, tier, language, release-type, deploy, install-command)
2. Run: `scripts/ci-sweep.sh --repo <name>`
3. Create test PR in the repo, verify CI green
4. If Tier 1: also add nightly.yml, claude-review.yml
5. If deploy: add TS_OAUTH secrets, create `production` environment with required reviewer

## Promoting a Repo (Tier 2 to Tier 1)

1. Update tier in `docs/TIER-ASSIGNMENTS.md`
2. Run: `scripts/ci-sweep.sh --repo <name>` (overwrites caller with Tier 1 template)
3. Add nightly.yml + claude-review.yml to the repo
4. Set up secrets: CODECOV_TOKEN, ANTHROPIC_API_KEY
5. Optionally: add deploy.yml + create `production` environment with approval gate

## Investigating CI Health Alerts

When `ci-health.py` sends a Telegram alert:

1. Check alert — which repo, which job failed
2. View recent runs: `gh run list --repo parthalon025/<repo> --limit 5`
3. View failed logs: `gh run view <id> --repo parthalon025/<repo> --log-failed`
4. If infrastructure issue (runner image, GitHub outage): wait + re-run
5. If code issue: fix on branch → PR → verify CI green

## SHA Pin Verification

Third-party actions must be SHA-pinned. @v4 tags are NOT acceptable in reusable workflows.

- Verify: `scripts/verify-pins.sh`
- To get a SHA for a tag: `gh api repos/{owner}/{repo}/git/ref/tags/{tag} --jq .object.sha`
- If the ref is annotated (returns `tag` type), dereference: `gh api repos/{owner}/{repo}/git/tags/{sha} --jq .object.sha`
