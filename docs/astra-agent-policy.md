# Astra agent policy

Use `gpt-6-astra` as the shared Codex default. The four active roles are:

| Role | Effort | Responsibility |
| --- | --- | --- |
| lead | medium | Requirements, implementation, integration, completion |
| investigator | medium | Evidence gathering and root-cause diagnosis |
| reviewer | high | Independent correctness, security, and operational review |
| validation-runner | low | Prescribed checks and precise failure reporting |

Use high effort for difficult investigation. Reserve xhigh, max, and ultra for
specific unusually difficult tasks; they are not permanent role tiers. Smaller
models are explicit exceptions after representative comparisons show useful
latency or usage savings without more corrections. Do not assume low-effort
Astra has the economics of a smaller model.

Use one agent for small changes. For substantial work, delegate a bounded
investigation or independent review when it improves progress or quality.
Additional workers need independent tasks and explicit file ownership. Keep the
lead working while workers run. Avoid mandatory manager-to-architect-to-builder
relays and recursive delegation by default. Workers return evidence, affected
paths, validation results, and unresolved questions rather than raw logs.

A reviewer receives requirements and the diff, with minimal implementer narrative.
Same-model agreement is not proof: use reproducible checks and source evidence.
Domain expertise belongs in focused skills and repository contracts, not model
seniority. Legacy Markdown agent names remain compatibility aliases; new work
uses the four roles above. Cross-provider pins remain explicit opt-in alternatives.

## Acceptance criteria and validation

- All four active Codex agents use a real model ID and a separate effort field.
- Native TOML definitions match the authored role instructions.
- Legacy names resolve to the same behavior without adding required handoffs.
- Generation checks catch model, effort, and instruction drift.
- Run repository test suites and generated-surface checks before completion.

Sources: [Astra guidance](https://developers.openai.com/api/docs/guides/latest-model)
and [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents).

The copied `test-pr.yml` routes homelab runners only in `Josh-Archer/home`.
Agent-setup uses its GitHub-hosted checks, including the dedicated matrix and
surface-drift workflows; it has no registered homelab runners.
