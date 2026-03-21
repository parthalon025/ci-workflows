# ci-workflows

## What

Centralized, reusable GitHub Actions workflows that provide standardized CI/CD across 24+ repositories. One repo to rule them all — change a workflow here, every consumer gets the update on their next CI run.

## Background

Managing CI/CD across 30+ repos led to configuration drift, redundant tooling (MegaLinter + Codety + SonarCloud doing the same job), and repos with zero CI. Inspired by DO-178C's Development Assurance Levels (aerospace software certification), this project applies **tiered criticality** — not all code deserves the same rigor.

Three tiers:

| Tier | What it covers | Pipeline |
|------|---------------|----------|
| **1: Production** | Running services, public packages | Lint + Test + Security + CodeQL + Nightly Deep Scan + AI Review + Release |
| **2: Active Dev** | Repos with tests, under development | Lint + Test + Security + Release |
| **3: Minimal** | Config-only, low-activity repos | Security scan + Dependabot |

## Why

- **One update, 24 repos.** Reusable workflows mean workflow logic lives here, not copy-pasted into every repo.
- **Tiered rigor saves CI minutes** while giving production code the scrutiny it deserves.
- **Supply chain security.** All third-party actions are SHA-pinned after the `tj-actions/changed-files` attack compromised 200+ repos in 2025.
- **Observable.** Cross-repo CI health dashboard with Telegram alerts. Nightly drift detection catches configuration divergence.

## Info

### Reusable Workflows (12)

| Workflow | Purpose |
|----------|---------|
| `reusable-lint-python` | ruff check + format + pip-audit |
| `reusable-lint-node` | npm lint + format:check |
| `reusable-test-python` | pytest with coverage, markers, codecov |
| `reusable-test-node` | npm test with optional build step |
| `reusable-test-custom` | Arbitrary test command (shell, bats, make) |
| `reusable-security` | Gitleaks full-history secret scan |
| `reusable-codeql` | GitHub CodeQL SAST analysis |
| `reusable-release` | Release Please automated versioning |
| `reusable-nightly` | Deep scan: dep audit + full tests + secrets + CodeQL |
| `reusable-claude-review` | AI code review via Claude Code Action |
| `reusable-deploy` | Tailscale SSH deploy with manual approval gate |

### Consumer Usage

Consumer repos call workflows with thin caller files (~15 lines):

```yaml
# .github/workflows/ci.yml in any consumer repo
jobs:
  lint:
    uses: parthalon025/ci-workflows/.github/workflows/reusable-lint-python.yml@v1
    secrets: inherit
  test:
    needs: lint
    uses: parthalon025/ci-workflows/.github/workflows/reusable-test-python.yml@v1
    secrets: inherit
```

### Deployment

`ci-sweep.sh` stamps the correct caller template into consumer repos:

```bash
scripts/ci-sweep.sh --repo my-project          # deploy based on TIER-ASSIGNMENTS.md
scripts/ci-sweep.sh --repo my-project --dry-run # preview changes
scripts/ci-sweep.sh --all                       # sweep all 24 repos
scripts/ci-sweep.sh --verify-only --all         # check for drift
scripts/ci-sweep.sh --secrets --all             # bootstrap GitHub secrets
```

### Versioning

- `@v1` — floating tag, latest stable. All consumers pin here.
- `@v1.x.y` — immutable point releases for auditability.
- Self-test CI must pass before any tag is created.

## So What

This system replaces ad-hoc, inconsistent CI across 30+ repos with a single source of truth. The result:

- **Zero-CI repos eliminated.** Every active repo now has at least security scanning.
- **Heavy tooling removed.** MegaLinter, Codety, and SonarCloud replaced with lightweight, fully-controlled ruff/eslint + CodeQL.
- **Aerospace-grade discipline at indie scale.** Tiered criticality, configuration control (drift detection), and self-testing CI infrastructure — patterns from DO-178C and SpaceX's SITL/HITL/VITL pyramid, adapted for a solo developer.

## Next Steps

- **Add a repo:** Edit `docs/TIER-ASSIGNMENTS.md`, run `ci-sweep.sh --repo <name>`
- **Promote a repo:** Change tier in `TIER-ASSIGNMENTS.md`, re-run `ci-sweep.sh`
- **Troubleshoot:** See `docs/RUNBOOK.md` for break-glass rollback, secret rotation, and CI health investigation
- **Design doc:** Full architecture and research at `docs/plans/2026-03-21-cicd-devops-pipeline-design.md` (in the Documents workspace)

---

Built with research from NASA JPL Power of Ten, DO-178C DAL framework, SpaceX SITL/HITL/VITL testing pyramid, and Google/Meta/Stripe CI infrastructure patterns.
