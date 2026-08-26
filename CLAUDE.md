# Claude Code Project Guidelines

## Agent Architecture & Rules
- This repository uses the canonical agent and delegation architecture defined in [`AGENTS.md`](AGENTS.md).
- Model matrix and tier pins are defined in [`models/matrix.json`](models/matrix.json).
- Generated surfaces (`.grok/`, `.agents/plugins/home-codex-agents/`, `.omp/agents/`) must be updated via `python3 scripts/sync_agent_surfaces.py`. Do not hand-edit generated files.

## Skills & Capabilities
- **Unslop**: Adhere to the anti-slop guidelines in [`.claude/skills/unslop/SKILL.md`](.claude/skills/unslop/SKILL.md). Eliminate inflated stock AI vocabulary (e.g., *delve*, *tapestry*, *testament*, *pivotal*, *beacon*), avoid conversational filler/throat-clearing, write clear and concise code comments, and keep communication grounded and direct.
- **Delegation**: Offload heavy multi-agent workloads to Grok Build or Antigravity via `grok-agy-delegate`.

## Testing & CI
- Before submitting changes, run:
  ```bash
  python3 scripts/promote_model_matrix.py --check
  python3 scripts/sync_agent_surfaces.py --check
  python3 -m unittest discover -s scripts/tests -v
  ```
- PR CI checks must pass before merging.
