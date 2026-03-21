# Tier Assignments

Source of truth for which repo gets which CI tier.

## Tiers

- **Tier 1: Production** — runs as service, handles data, or public package. Full pipeline.
- **Tier 2: Active Dev** — has tests, active development, not production-critical.
- **Tier 3: Minimal** — config-only or low-activity. Gitleaks + dependabot only.

## Assignments

| Tier | Repo | Language | Release Type | Deploy | Install Command |
|------|------|----------|-------------|--------|-----------------|
| 1 | ha-aria | python | simple | yes | pip install -e ".[dev]" |
| 1 | ollama-queue | python | simple | yes | pip install -e ".[dev]" |
| 1 | lessons-db | python | simple | yes | pip install -e ".[dev]" |
| 1 | telegram-agent | python | simple | yes | pip install -e ".[dev]" |
| 1 | telegram-brief | python | simple | yes | pip install -e ".[dev]" |
| 1 | telegram-capture | python | simple | yes | pip install -e ".[dev]" |
| 1 | notion-tools | python | simple | yes | pip install -e ".[dev]" |
| 1 | warmpath | python | simple | yes | pip install -e ".[dev]" |
| 1 | superhot-ui | node | node | no | npm ci |
| 1 | vector | mixed | simple | yes | pip install -e ".[dev]" |
| 2 | project-hub | node | node | no | npm ci |
| 2 | expedition33-ui | node | node | no | npm ci |
| 2 | ui-template | node | node | no | npm ci |
| 2 | autonomous-coding-toolkit | node | node | no | npm ci |
| 2 | terminalai | python | simple | no | pip install -e ".[dev]" |
| 2 | google-oauth2 | mixed | simple | no | pip install -e ".[dev]" |
| 2 | template-python | python | simple | no | pip install -e ".[dev]" |
| 2 | template-node | node | node | no | npm ci |
| 2 | claude-onboarding-kit | shell | simple | no | — |
| 2 | Project | mixed | simple | no | pip install -e ".[dev]" |
| 3 | claude-agent-system | config | — | no | — |
| 3 | claude-config | shell | — | no | — |
| 3 | homeassistant | yaml | — | no | — |
| 3 | bitnet-local | shell | — | no | — |

## Excluded

| Repo | Reason |
|------|--------|
| framecast | Bespoke 10-workflow pipeline (too specialized) |
| Aperant | Fork with 15 upstream workflows |
| ground-station | External clone (not owned) |
| PLFM_RADAR | External clone (not owned) |
| LLM-Agents-CRM | 7mo+ inactive |
| Second-Brain | Empty repo |
| LLM-Agent-Memory | Empty repo |
| NVIDIA-RTX-Video-GUI | Empty repo |
| All forks | Upstream-managed |
