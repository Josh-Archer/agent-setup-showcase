# Agent Setup Showcase

Sanitized snapshot of agent-related configuration folders (from `origin/main` of the homelab workspace):

- `.codex` — Codex agents + skills
- `.gemini` — Gemini / Antigravity agents + skills
- `.github` — GitHub agent definitions + workflows
- `.claude` — Claude Code agents
- `.grok` — Grok agents + roles
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
powershell -ExecutionPolicy Bypass -File .\scripts\validate-homelab-mcp.ps1
```

This:

1. Syncs agent/skill trees into `~/.codex`, `~/.claude`, `~/.gemini`
2. Installs PowerShell profile hooks that load `HOMELAB_MCP_API_KEY` and `PAPERLESS_API_KEY` (precedence: process → user → **kubectl** → cache; fail-loud, see [mcp/README.md](mcp/README.md))
3. Registers Paperless + Immich MCP for **Codex**, **Grok**, and **Antigravity (agy) / Gemini**

### Linux / macOS / WSL

```bash
cd path/to/agent-setup-showcase
chmod +x scripts/setup_agents.sh
./scripts/setup_agents.sh
# new shell or:
source ~/.zshrc   # or ~/.bashrc
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
| Immich | `http://immich-mcp.archer.casa/mcp` | LAN/Tailscale allowlist only |

Fragments live under `mcp/fragments/`. See [mcp/README.md](mcp/README.md).

**Never commit** `~/.config/homelab/mcp-api-key`, `paperless-api-key`, or real token values.

## Delegation (Grok Build + Antigravity)

The repository includes a Codex skill for delegating work to Grok Build and Antigravity (`agy`), including dependency-aware multi-agent plans.

- [Agent Architecture map](AGENTS.md) — canonical roles and model equivalences
- [Grok & Antigravity Delegation Guide](docs/grok-agy-delegation.md) — setup, CLI examples, plan schema

### Install delegation globally

```bash
python3 scripts/setup_global_delegation.py
```

This symlinks surfaces into `~/.codex/skills/`, `~/.grok/`, and `~/.agents/plugins/`, and adds an idempotent startup marker to `~/.zshrc`.

### Local validation for agent surfaces

```bash
python3 scripts/sync_agent_surfaces.py --check
python3 -m unittest discover -s scripts/tests -v
```

## Update source

Refresh agent snapshots from `C:\Code\agent-setup-main` (or the homelab `home` repo agent trees) and re-run setup.
