# Homelab MCP (Paperless + Immich)

Shared MCP client config for **Codex**, **Grok**, and **Antigravity (agy) / Gemini**.

**No secrets are stored in this repo.** Auth uses the process environment variable:

| Variable | Used by | Purpose |
| -------- | ------- | ------- |
| `HOMELAB_MCP_API_KEY` | Paperless (mcpo) | `Authorization: Bearer â€¦` client key (`mcp/paperless-mcp-secret` â†’ `API_KEY`) |
| `PAPERLESS_API_KEY` | Paperless (stdio MCP) | Paperless-NGX token (`mcp/paperless-mcp-secret` → `PAPERLESS_API_TOKEN`); used by `npx @baruchiro/paperless-mcp` (Grok) |

Immich MCP has **no edge API key** (LAN/Tailscale allowlist only). Prefer a **read-only** Immich API key in the cluster (`mcp/immich-mcp-secret` â†’ `IMMICH_API_KEY`).

## Secret load precedence (fail-loud)

Profile snippets (`shell/homelab-mcp.env.sh`, `shell/homelab-mcp.ps1`) and the shared policy module (`scripts/homelab_mcp_secret_load.py`) resolve each key in this order:

| Priority | Source | Notes |
| -------- | ------ | ----- |
| 1 | **Process env** | Already exported in this shell / agent process |
| 2 | **User env** (Windows) | `[Environment]::GetEnvironmentVariable(..., 'User')` |
| 3 | **kubectl secret** | Live `mcp/paperless-mcp-secret`; **refreshes** local cache (+ User env on Windows) |
| 4 | **Cache file** | `~/.config/homelab/mcp-api-key` or `paperless-api-key` â€” **offline fallback only** |

**Why kubectl before cache:** a stale cache file used to win silently when it still contained a rotated/dead API key, so MCP looked â€œconfiguredâ€ while every call failed. Live cluster secrets now outrank the cache whenever `kubectl` can read them.

**Fail-loud behavior:**

- Missing key after all sources â†’ warning on stderr / `Write-Warning` (not a silent no-op).
- Cache used while kubectl is missing or returned empty â†’ warning that the key may be stale.
- Cache that differs from kubectl â†’ refresh cache from cluster and warn.

**Optional lightweight probe** (disabled by default so interactive shells stay fast):

```bash
export HOMELAB_MCP_KEY_PROBE=1
# optional override (default: http://paperless-mcp.archer.casa/docs)
export HOMELAB_MCP_KEY_PROBE_URL='http://paperless-mcp.archer.casa/docs'
```

When probe is on, a rejected candidate is skipped and the next source is tried (still fail-loud if none work). Policy unit tests: `python3 -m unittest scripts.tests.test_secret_load_order -v`.

## Endpoints (LAN / Tailscale)

| Server | URL / transport | Client auth |
| ------ | --- | ----------- |
| Paperless (mcpo OpenAPI) | `http://paperless-mcp.archer.casa` | Bearer `${HOMELAB_MCP_API_KEY}` (OpenAPI clients) |
| Paperless (native MCP) | **stdio** `npx @baruchiro/paperless-mcp` | `${PAPERLESS_API_KEY}` (Grok / real MCP clients) |
| Immich | `http://immich-mcp.archer.casa/mcp` | none (LAN/Tailscale allowlist) |

> **Grok note:** Cluster `paperless-mcp` is **mcpo** (MCPâ†’OpenAPI). Grok speaks streamable HTTP MCP, so Paperless is installed as **stdio** `npx`. Immich is native HTTP MCP. If `immich-mcp.archer.casa` does not resolve, install falls back to Traefikâ€™s Tailscale IP + `Host` header (`HOMELAB_TRAEFIK_TS_IP`, default `100.68.151.94`).

See also `home` repo `docs/mcp-catalog.md`.

## Immich LAN / Tailscale allowlist

Immich MCP is **allowlist-only at the HTTP edge** (no Bearer / API key on ingress). Cluster middleware `immich-mcp-local-allowlist` permits:

| CIDR | Meaning |
| ---- | ------- |
| `192.168.0.0/16` | Home LAN |
| `100.64.0.0/10` | Tailscale CGNAT range |
| `127.0.0.1/32` | Loopback |

**Expectations:**

1. Client must be on **home LAN** or **Tailscale** (or loopback).
2. Hostname `immich-mcp.archer.casa` must resolve (AdGuard rewrite, `/etc/hosts` via `setup_agents.sh`, or MagicDNS).
3. Do **not** attach Immich MCP to a public Traefik entrypoint without additional auth.
4. Prefer a **read-only** Immich user API key in Vaultwarden / `mcp/immich-mcp-secret` (used only inside the pod).

Optional env for install/validate when DNS is broken:

| Variable | Purpose |
| -------- | ------- |
| `HOMELAB_TRAEFIK_TS_IP` | Traefik Tailscale VIP used as Immich URL fallback + `Host: immich-mcp.archer.casa` |

### Immich failure modes (actionable)

| Symptom | Likely cause | What to do |
| ------- | ------------ | ---------- |
| DNS resolve failed | No rewrite / hosts / MagicDNS | Re-run `setup_agents.sh` hosts block, or set AdGuard; or use `HOMELAB_TRAEFIK_TS_IP` |
| Connect / HTTP **timeout** (5s) | Not on LAN/TS, broken route, or edge down | Join Tailscale or LAN; check Traefik; **do not wait on MCP handshake** |
| HTTP **403** | Source IP outside allowlist | Use Tailscale IP or home LAN; do not expose publicly |
| Connection **refused** | Traefik / `immich-mcp` down | `kubectl -n mcp get deploy,po,svc,ingress -l app=immich-mcp` |
| In-cluster `/health` OK, client fail | Host DNS/routing only | Fix DNS or VIP+Host fallback; re-install MCP clients |
| MCP client **silent hang** | Streamable-HTTP handshake to unreachable URL | Run validate first (timed probe); fragments set `startup_timeout_sec` / `timeout` |

Health path (no MCP handshake): `GET http://immich-mcp.archer.casa/health`  
MCP path (clients): `http://immich-mcp.archer.casa/mcp`

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

Bootstrap registers **Immich alongside Paperless** for:

| Client | Immich transport | Notes |
| ------ | ---------------- | ----- |
| Codex | HTTP URL `/mcp` | `startup_timeout_sec = 30` in fragment |
| Grok | HTTP URL `/mcp` | DNS fallback â†’ VIP + `Host` header |
| Gemini / Antigravity | HTTP URL `/mcp` | `timeout: 30000` ms in JSON fragments |

**Validate (no secrets printed; timed Immich probe):**

```powershell
# Local end-state: agents, env hooks, MCP config (Windows)
powershell -ExecutionPolicy Bypass -File .\scripts\test-windows-bootstrap-endstate.ps1

# Full MCP smoke (Immich /health probe, default 5s timeout, fails fast with remediation)
powershell -ExecutionPolicy Bypass -File .\scripts\validate-homelab-mcp.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\validate-homelab-mcp.ps1 -TimeoutSec 5 -SkipCluster
```

Partial installs exit non-zero with the missing step. Re-run
`setup_agents.ps1` / `install-homelab-mcp.ps1` (idempotent). Details:
[docs/windows-bootstrap.md](../docs/windows-bootstrap.md).

```bash
# Linux / macOS / WSL
chmod +x scripts/validate-homelab-mcp.sh
./scripts/validate-homelab-mcp.sh
./scripts/validate-homelab-mcp.sh --timeout 5 --skip-cluster
```

Validate checks:

1. Client config presence (Codex / Grok / Gemini / Antigravity) for **paperless + immich**
2. Env key presence (lengths only)
3. **Client-side Immich `/health` + `/mcp` reachability** with a short timeout (no MCP initialize handshake)
4. Optional in-cluster `kubectl exec … /health` and Paperless Bearer smoke
5. Local config secret-leak scan

## Fragments

| File | Target |
| ---- | ------ |
| `fragments/codex.homelab-mcp.toml` | Append / merge into `~/.codex/config.toml` |
| `fragments/grok.homelab-mcp.toml` | Merge into `~/.grok/config.toml` |
| `fragments/gemini.mcpServers.json` | Merge into `~/.gemini/settings.json` â†’ `mcpServers` |
| `fragments/antigravity.mcp_config.json` | Merge into `~/.gemini/antigravity/mcp_config.json` |

Codex uses `bearer_token_env_var` so the token never appears in the TOML file.
Grok Paperless uses `${PAPERLESS_API_KEY}` in stdio env; Immich has no client secret.
Gemini / Antigravity use `${HOMELAB_MCP_API_KEY}` in Paperless header maps (resolved at runtime by the client).
