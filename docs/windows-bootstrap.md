# Windows bootstrap (agents + env hooks + MCP)

This guide covers the **Windows PowerShell** install path for `agent-setup`:
agent trees, profile env hooks, and Homelab MCP client registration.

Related scripts:

| Script | Purpose |
| ------ | ------- |
| `scripts/setup_agents.ps1` | Full bootstrap (agents + hooks + MCP) |
| `scripts/install-homelab-mcp.ps1` | MCP clients only |
| `scripts/test-windows-bootstrap-endstate.ps1` | Local end-state checks (agents, hooks, MCP config) |
| `scripts/validate-homelab-mcp.ps1` | Deeper MCP smoke (env key, config, optional cluster) |

## First-time install

From a clone of this repo:

```powershell
cd path\to\agent-setup
powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1 -LoadKeyFromCluster
```

`setup_agents.ps1` always finishes with **end-state validation**. A partial
install exits **non-zero** and prints the failed step plus a recovery hint.

Optional deeper connectivity (kubectl / in-cluster):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\validate-homelab-mcp.ps1
```

## What “healthy end-state” means

| Area | Expectation |
| ---- | ----------- |
| **Agents** | `~\.codex\agents`, `~\.claude\agents`, `~\.gemini\agents` mirror the repo trees |
| **Env hooks** | `~\.config\homelab\homelab-mcp.ps1` exists; Windows PowerShell + PowerShell 7 profiles contain the `homelab-mcp (agent-setup-showcase)` marker block |
| **MCP config** | Codex / Grok TOML and Gemini / Antigravity JSON include `paperless` + `immich` |
| **Key** | `HOMELAB_MCP_API_KEY` present via process env, User env, or `~\.config\homelab\mcp-api-key` (value never printed) |

## Idempotency

Safe to re-run after any partial failure:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1 -LoadKeyFromCluster
powershell -ExecutionPolicy Bypass -File .\scripts\test-windows-bootstrap-endstate.ps1
```

| Step | Re-run behavior |
| ---- | --------------- |
| Agent trees | `robocopy /MIR` from repo → user home (no manual cleanup) |
| Profile hooks | Marker block is replaced in place (start/end markers) |
| MCP TOML/JSON | Prior `paperless` / `immich` blocks are stripped then re-merged; backups `*.bak-homelab-mcp-*` |
| Keys | User env + cache file refreshed when `-LoadKeyFromCluster` or env already set |

No secrets are written into git-tracked files. Config fragments only reference
`${HOMELAB_MCP_API_KEY}` / `bearer_token_env_var` / `${PAPERLESS_API_KEY}`.

## Partial failure recovery

| Failed step prefix | Meaning | Fix |
| ------------------ | ------- | --- |
| `agents.*` | Agent trees missing or incomplete under `~` | Re-run `setup_agents.ps1` from a full clone |
| `hooks.snippet` | `~\.config\homelab\homelab-mcp.ps1` missing | Re-run `setup_agents.ps1` |
| `hooks.profile` | Profile missing marker or snippet source | Re-run `setup_agents.ps1` |
| `mcp.codex` / `mcp.grok` / `mcp.gemini` / `mcp.antigravity` | Client config incomplete | Re-run `install-homelab-mcp.ps1` or full setup |
| `mcp.*.cli` | CLI list out of sync with expected servers | Re-run `install-homelab-mcp.ps1` (CLI present) |
| `env.key` | No API key in process / User env / cache | `setup_agents.ps1 -LoadKeyFromCluster` or set User env manually |

If end-state fails, do **not** assume a green install. Fix the listed step, then
re-run the end-state script until it exits 0.

### Manual key bootstrap (no cluster)

```powershell
# Set User env (never commit the value)
[Environment]::SetEnvironmentVariable('HOMELAB_MCP_API_KEY', '<from Vaultwarden>', 'User')
$env:HOMELAB_MCP_API_KEY = [Environment]::GetEnvironmentVariable('HOMELAB_MCP_API_KEY', 'User')
powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1
```

See [mcp/README.md](../mcp/README.md) for cluster `kubectl` key pull examples.

## Scripted smoke check (Windows)

Local-only (CI-friendly / offline-safe aside from optional CLI list):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-windows-bootstrap-endstate.ps1
echo $LASTEXITCODE   # expect 0
```

Soft key check (when intentionally skipping secret bootstrap):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-windows-bootstrap-endstate.ps1 -SkipRequireKey
```

## After success

1. Open a **new** terminal so profile hooks load env vars.
2. Restart Codex / Grok / Antigravity so they reload MCP config and User env.
3. Optional: `validate-homelab-mcp.ps1` for live auth smoke when kubectl is available.
