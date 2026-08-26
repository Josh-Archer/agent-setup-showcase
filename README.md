# Agent Setup Showcase

Sanitized snapshot of agent-related configuration folders (from `origin/main` of the homelab workspace):

- `.codex` — Codex agents + skills
- `.gemini` — Gemini / Antigravity agents + skills
- `.github` — GitHub agent definitions + workflows
- `.claude` — Claude Code agents
- `.grok` — Grok agents + roles
- `.omp` — Oh My Pi agents + skills
- `mcp/` — Homelab MCP client fragments (Paperless + Immich)
- `shell/` — Shell profile snippets (zsh/bash + PowerShell)
- `scripts/` — Bootstrap + validate + agent surface sync

## Notes

- Obvious hardcoded secrets were scrubbed from the snapshot.
- Platform secret references (`${{ secrets.* }}`, env lookups, `${HOMELAB_MCP_API_KEY}`, `${PAPERLESS_API_KEY}`) are intentional and not plaintext credentials.
- Multi-agent run artifacts land under `.agent-runs/` (gitignored).

## One-command bootstrap (agents + skills + MCP)

Same idea as installing agent/skill definitions: run once per machine.

### Windows

```powershell
cd path\to\agent-setup-showcase
powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1 -LoadKeyFromCluster
# setup_agents.ps1 exits non-zero if end-state is incomplete (agents / hooks / MCP)
powershell -ExecutionPolicy Bypass -File .\scripts\test-windows-bootstrap-endstate.ps1
# optional live/cluster smoke:
powershell -ExecutionPolicy Bypass -File .\scripts\validate-homelab-mcp.ps1
```

This:

1. Syncs agent/skill trees into `~/.codex`, `~/.claude`, `~/.gemini`
2. Installs PowerShell profile hooks that load `HOMELAB_MCP_API_KEY` and `PAPERLESS_API_KEY` (precedence: process Ã¢â€ â€™ user Ã¢â€ â€™ **kubectl** Ã¢â€ â€™ cache; fail-loud, see [mcp/README.md](mcp/README.md))
3. Registers Paperless + Immich MCP for **Codex**, **Grok**, and **Antigravity (agy) / Gemini**
4. Validates end-state and fails the bootstrap if anything is only half-installed
5. Validate probes Immich `/health` with a short timeout (actionable failures; no silent handshake hang)

**Partial failure / re-run:** install steps are idempotent. Re-run `setup_agents.ps1`, then the end-state script until exit code 0. See [docs/windows-bootstrap.md](docs/windows-bootstrap.md).

### Linux / macOS / WSL

```bash
cd path/to/agent-setup-showcase
chmod +x scripts/setup_agents.sh scripts/validate-homelab-mcp.sh
./scripts/setup_agents.sh
# new shell or:
source ~/.zshrc   # or ~/.bashrc
./scripts/validate-homelab-mcp.sh
```

Hooks are idempotent blocks in `~/.zshrc` and `~/.bashrc` marked:

```text
# >>> homelab-mcp (agent-setup-showcase) >>>
...
# <<< homelab-mcp (agent-setup-showcase) <<<
```

## Homelab MCP (no secrets in git)

| Server | Transport | Auth |
|--------|-----------|------|
| Paperless (Grok / native MCP) | stdio `npx @baruchiro/paperless-mcp` | `${PAPERLESS_API_KEY}` |
| Paperless (mcpo OpenAPI) | `http://paperless-mcp.archer.casa` | Bearer `${HOMELAB_MCP_API_KEY}` |
| Immich | `http://immich-mcp.archer.casa/mcp` | LAN/Tailscale allowlist only (`192.168.0.0/16`, `100.64.0.0/10`, loopback) |

Fragments live under `mcp/fragments/`. See [mcp/README.md](mcp/README.md) for **allowlist expectations**, Immich DNS/Tailscale fallback, timed health probes, and failure-mode remediation.

**Never commit** `~/.config/homelab/mcp-api-key`, `paperless-api-key`, or real token values.

## Delegation (Grok Build + Antigravity)

The repository includes a Codex skill for delegating work to Grok Build and Antigravity (`agy`), including dependency-aware multi-agent plans.

- [Agent Architecture map](AGENTS.md) — canonical roles and model equivalences
- [Versioned model matrix](docs/model-matrix.md) — promote pins across Codex/Claude/Gemini/Grok
- [Grok & Antigravity Delegation Guide](docs/grok-agy-delegation.md) — setup, CLI examples, plan schema

### Install delegation globally

```bash
python3 scripts/setup_global_delegation.py
```

This symlinks surfaces into `~/.codex/skills/`, `~/.grok/`, and `~/.agents/plugins/`, and adds an idempotent startup marker to `~/.zshrc`.

### Local validation for agent surfaces

```bash
python scripts/promote_model_matrix.py --check
python scripts/sync_agent_surfaces.py --check
python -m unittest discover -s scripts/tests -v
```

Default `scripts/sync_agent_surfaces.py` is **safe** (no deletes). After
renaming or deleting Codex agents, re-run with `--prune` only when you intend
to remove stale generated Grok/Antigravity surfaces. See
[docs/grok-agy-delegation.md](docs/grok-agy-delegation.md#stale-surfaces-after-rename-or-delete).

### Promote a new model generation

Edit `models/matrix.json` (bump `matrix_version` and provider pins), then:

```bash
python scripts/promote_model_matrix.py
python scripts/promote_model_matrix.py --check
```

See [docs/model-matrix.md](docs/model-matrix.md).

CI runs the same checks on every PR and push to `master` via
[`.github/workflows/agent-surface-drift.yml`](.github/workflows/agent-surface-drift.yml).
Drift in model equivalence, missing role files, or content mismatch fails the job.

## Update source / refresh snapshots

Canonical roles live under `.codex/agents/*.agent.md`. Generated surfaces under
`.grok/` and `.agents/plugins/home-codex-agents/` must not be hand-edited.

To regenerate committed snapshots after editing Codex agents:

```bash
# From this repository root
python3 scripts/sync_agent_surfaces.py
python3 scripts/sync_agent_surfaces.py --check
python3 -m unittest discover -s scripts/tests -v
git add .grok .agents/plugins/home-codex-agents
git commit -m "chore(agents): regenerate surfaces from Codex agents"
```

To refresh the whole agent snapshot tree from the homelab source (when
re-exporting this showcase):

1. Copy/update agent trees from the home monorepo (or `C:\Code\agent-setup-main`)
   Ã¢â‚¬â€ typically `.codex/`, `.claude/`, `.gemini/`, `.grok/`, `.agents/`.
2. Ensure canonical roles are correct under `.codex/agents/`.
3. Run `python3 scripts/sync_agent_surfaces.py` so Grok/agy surfaces match.
4. Re-run setup scripts (`scripts/setup_agents.ps1` / `scripts/setup_agents.sh`)
   on machines that install into `~/.codex`, `~/.claude`, etc.
