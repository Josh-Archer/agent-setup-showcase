# Homelab MCP (Paperless + Immich)

Shared MCP client config for **Codex**, **Grok**, and **Antigravity (agy) / Gemini**.

**No secrets are stored in this repo.** Auth uses the process environment variable:

| Variable | Used by | Purpose |
| -------- | ------- | ------- |
| `HOMELAB_MCP_API_KEY` | Paperless (mcpo) | `Authorization: Bearer …` client key (`mcp/paperless-mcp-secret` → `API_KEY`) |

Immich MCP has **no edge API key** (LAN/Tailscale allowlist only). Prefer a **read-only** Immich API key in the cluster.

## Endpoints (LAN / Tailscale)

| Server | URL / transport | Client auth |
| ------ | --- | ----------- |
| Paperless (mcpo OpenAPI) | `http://paperless-mcp.archer.casa` | Bearer `${HOMELAB_MCP_API_KEY}` (OpenAPI clients) |
| Paperless (native MCP) | **stdio** `npx @baruchiro/paperless-mcp` | `${PAPERLESS_API_KEY}` (Grok / real MCP clients) |
| Immich | `http://immich-mcp.archer.casa/mcp` | none (LAN/Tailscale allowlist) |

> **Grok note:** Cluster `paperless-mcp` is **mcpo** (MCP→OpenAPI). Grok speaks streamable HTTP MCP, so Paperless is installed as **stdio** `npx`. Immich is native HTTP MCP. If `immich-mcp.archer.casa` does not resolve, install falls back to Traefik’s Tailscale IP + `Host` header.

See also `home` repo `docs/mcp-catalog.md`.

## One-time secret bootstrap (local machine only)

Pull the shared mcpo API key from the cluster into your **user** environment (never commit it):

```powershell
# Windows (PowerShell)
$key = [Text.Encoding]::UTF8.GetString(
  [Convert]::FromBase64String(
    (kubectl -n mcp get secret paperless-mcp-secret -o jsonpath='{.data.API_KEY}')
  )
)
[Environment]::SetEnvironmentVariable('HOMELAB_MCP_API_KEY', $key, 'User')
$env:HOMELAB_MCP_API_KEY = $key
```

```bash
# Linux / macOS
export HOMELAB_MCP_API_KEY="$(kubectl -n mcp get secret paperless-mcp-secret -o jsonpath='{.data.API_KEY}' | base64 -d)"
# persist via your shell profile or systemd user env as preferred
```

Restart terminals / agent apps after setting the variable.

## Install into global agent configs

**Preferred (agents + skills + shell + MCP):**

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1 -LoadKeyFromCluster
```

```bash
# Linux / macOS / WSL
./scripts/setup_agents.sh
source ~/.zshrc
```

**MCP-only:**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-homelab-mcp.ps1 -LoadKeyFromCluster
```

Or manually apply the fragments under `mcp/fragments/`.

**Validate (no secrets printed):**

```powershell
# Local end-state: agents, env hooks, MCP config (Windows)
powershell -ExecutionPolicy Bypass -File .\scripts\test-windows-bootstrap-endstate.ps1

# Full MCP smoke (includes end-state + optional cluster probes)
powershell -ExecutionPolicy Bypass -File .\scripts\validate-homelab-mcp.ps1
```

Partial installs exit non-zero with the missing step. Re-run
`setup_agents.ps1` / `install-homelab-mcp.ps1` (idempotent). Details:
[docs/windows-bootstrap.md](../docs/windows-bootstrap.md).

## Fragments

| File | Target |
| ---- | ------ |
| `fragments/codex.homelab-mcp.toml` | Append / merge into `~/.codex/config.toml` |
| `fragments/grok.homelab-mcp.toml` | Merge into `~/.grok/config.toml` |
| `fragments/gemini.mcpServers.json` | Merge into `~/.gemini/settings.json` → `mcpServers` |
| `fragments/antigravity.mcp_config.json` | Merge into `~/.gemini/antigravity/mcp_config.json` |

Codex uses `bearer_token_env_var` so the token never appears in the TOML file.
Grok uses `${HOMELAB_MCP_API_KEY}` expansion in headers.
Gemini / Antigravity use `${HOMELAB_MCP_API_KEY}` in header maps (resolved at runtime by the client).
