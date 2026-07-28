# Repository agent constitution (Antigravity)

Antigravity does not auto-load the repository root `AGENTS.md`. Use this rule together with the role body when working in this repo.

## Source of truth

- Canonical roles: `.codex/agents/*.agent.md`
- Cross-provider contract: repository root `AGENTS.md`
- Operational guide: `docs/grok-agy-delegation.md`
- Regenerate Grok/agy surfaces: `python3 scripts/sync_agent_surfaces.py`
- Drift check: `python3 scripts/sync_agent_surfaces.py --check`
- Prune stale surfaces after rename/delete: `python3 scripts/sync_agent_surfaces.py --prune`

## Delegation handoffs

- Single-agent wrapper: `.codex/skills/grok-agy-delegate/scripts/delegate.py`
- Plan orchestrator: `.codex/skills/grok-agy-delegate/scripts/orchestrate.py`
- Multi-agent outputs: `.agent-runs/<run-id>/` (local, gitignored)
- Dependents are not run when a prerequisite fails, times out, or is skipped

## Safety

- Do not put secrets into prompts or plan JSON
- Prefer read-only roles for analysis-only work
- Inspect `git diff` before treating delegated edits as accepted
- Ensure Git commit GPG/SSH signing is enabled using the default global signing key (e.g. from Bitwarden/ssh-agent), and your SSH agent/Bitwarden vault is unlocked when tasks are running so commits can be signed successfully.
- `--prune` deletes generated surface files that no longer map to a Codex agent; default sync never deletes without that flag.
