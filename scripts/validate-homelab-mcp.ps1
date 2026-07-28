#Requires -Version 5.1
<#
.SYNOPSIS
  Validate Homelab MCP connectivity without printing secrets.

.DESCRIPTION
  Runs local Windows end-state checks (agents, env hooks, MCP config) first,
  then optional live/cluster smoke. Partial failure exits non-zero with
  actionable recovery hints (see docs/windows-bootstrap.md).

.PARAMETER SkipEndState
  Skip the shared end-state script (agents/hooks/MCP config). Not recommended.

.PARAMETER SkipCluster
  Skip kubectl/in-cluster health probes.
#>
[CmdletBinding()]
param(
  [switch]$SkipEndState,
  [switch]$SkipCluster
)

$ErrorActionPreference = 'Continue'
$failed = 0
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Ok($m) { Write-Host "OK  $m" -ForegroundColor Green }
function Bad($m) {
  Write-Host "FAIL $m" -ForegroundColor Red
  $script:failed++
}

# Shared local end-state (agents + hooks + MCP config + key presence)
if (-not $SkipEndState) {
  $endState = Join-Path $RepoRoot 'scripts\test-windows-bootstrap-endstate.ps1'
  if (-not (Test-Path -LiteralPath $endState)) {
    Bad "missing end-state script: $endState"
  } else {
    Write-Host '--- Windows end-state (agents, hooks, MCP config) ---' -ForegroundColor Cyan
    # Child process: validator uses exit codes without aborting this script early.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $endState -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) {
      Bad 'Windows end-state validation failed (see messages above; re-run setup_agents.ps1)'
    } else {
      Ok 'Windows end-state validation'
    }
  }
  Write-Host ''
}

# Load env from profile snippet if needed
$snip = Join-Path $env:USERPROFILE '.config\homelab\homelab-mcp.ps1'
if (Test-Path $snip) { . $snip }

if ([string]::IsNullOrWhiteSpace($env:HOMELAB_MCP_API_KEY)) {
  Bad 'HOMELAB_MCP_API_KEY is not set in this process (open a new terminal after setup, or -LoadKeyFromCluster)'
} else {
  Ok "HOMELAB_MCP_API_KEY present (len=$($env:HOMELAB_MCP_API_KEY.Length))"
}

# Config presence (duplicate of end-state for standalone MCP focus / older callers)
function Test-ConfigPattern([string]$Path, [string]$Pattern) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  return [bool](Select-String -Path $Path -Pattern $Pattern -Quiet -ErrorAction SilentlyContinue)
}
$cfgChecks = @(
  @{ Name = 'codex paperless'; Path = "$env:USERPROFILE\.codex\config.toml"; Pattern = 'mcp_servers\.paperless' },
  @{ Name = 'codex immich'; Path = "$env:USERPROFILE\.codex\config.toml"; Pattern = 'mcp_servers\.immich' },
  @{ Name = 'grok paperless'; Path = "$env:USERPROFILE\.grok\config.toml"; Pattern = 'mcp_servers\.paperless' },
  @{ Name = 'grok immich'; Path = "$env:USERPROFILE\.grok\config.toml"; Pattern = 'mcp_servers\.immich' }
)
foreach ($c in $cfgChecks) {
  if (Test-ConfigPattern $c.Path $c.Pattern) {
    Ok $c.Name
  } else {
    Bad "$($c.Name) - re-run scripts\install-homelab-mcp.ps1"
  }
}

try {
  $gs = Get-Content "$env:USERPROFILE\.gemini\settings.json" -Raw | ConvertFrom-Json
  if ($gs.mcpServers.paperless -and $gs.mcpServers.immich) { Ok 'gemini mcpServers' } else { Bad 'gemini mcpServers - re-run install-homelab-mcp.ps1' }
} catch { Bad "gemini settings: $_" }

try {
  $agy = Get-Content "$env:USERPROFILE\.gemini\antigravity\mcp_config.json" -Raw | ConvertFrom-Json
  if ($agy.mcpServers.paperless -and $agy.mcpServers.immich) { Ok 'antigravity mcp_config' } else { Bad 'antigravity mcp_config - re-run install-homelab-mcp.ps1' }
} catch { Bad "antigravity: $_" }

# In-cluster health (works even if DNS for archer.casa fails on this host)
if (-not $SkipCluster) {
  if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    $imm = kubectl -n mcp exec deploy/immich-mcp -- curl -sS http://127.0.0.1:5000/health 2>$null
    if ("$imm" -match 'healthy') { Ok 'immich-mcp /health in-cluster' } else { Bad "immich-mcp health: $imm (is cluster context correct?)" }

    if (-not [string]::IsNullOrWhiteSpace($env:HOMELAB_MCP_API_KEY)) {
      $code = kubectl -n mcp run "curl-pl-val-$([guid]::NewGuid().ToString('N').Substring(0,8))" --rm -i --restart=Never --image=curlimages/curl:8.5.0 --quiet -- `
        curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $($env:HOMELAB_MCP_API_KEY)" `
        http://paperless-mcp.mcp.svc.cluster.local:8080/docs 2>$null
      # kubectl noise may wrap output
      if ("$code" -match '200') { Ok 'paperless-mcp /docs Bearer auth 200' } else { Bad "paperless-mcp auth code=$code" }
    }
  } else {
    Write-Host 'WARN kubectl not available; skipping in-cluster smoke (use -SkipCluster to silence)' -ForegroundColor Yellow
  }
}

# CLI lists
if (Get-Command codex -ErrorAction SilentlyContinue) {
  $list = codex mcp list 2>&1 | Out-String
  if ($list -match 'paperless' -and $list -match 'immich') { Ok 'codex mcp list has paperless+immich' } else { Bad 'codex mcp list missing entries' }
}
if (Get-Command grok -ErrorAction SilentlyContinue) {
  $list = grok mcp list 2>&1 | Out-String
  if ($list -match 'paperless' -and $list -match 'immich') { Ok 'grok mcp list has paperless+immich' } else { Bad 'grok mcp list missing entries' }
}

# Secret leakage quick audit of local configs (no values printed)
$scanFiles = @(
  "$env:USERPROFILE\.codex\config.toml",
  "$env:USERPROFILE\.grok\config.toml",
  "$env:USERPROFILE\.gemini\settings.json",
  "$env:USERPROFILE\.gemini\antigravity\mcp_config.json"
)
$bearerLiteral = 'Bearer [A-Za-z0-9_\-]{20,}'
$bearerEnv = 'Bearer \$\{'
foreach ($f in $scanFiles) {
  if (-not (Test-Path $f)) { continue }
  $raw = Get-Content -Raw $f
  $hasLiteralBearer = ($raw -match $bearerLiteral) -and ($raw -notmatch $bearerEnv)
  $hasEnvForm = ($raw -match 'bearer_token_env_var') -or ($raw -match '\$\{HOMELAB_MCP_API_KEY\}') -or ($raw -match $bearerEnv)
  if ($hasLiteralBearer -and -not $hasEnvForm) {
    Bad "possible secret in $f"
  } else {
    Ok "no literal secrets in $f"
  }
}

if ($failed -gt 0) {
  Write-Host "`n$failed check(s) failed" -ForegroundColor Red
  Write-Host 'Recovery (idempotent): powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1 -LoadKeyFromCluster' -ForegroundColor Yellow
  Write-Host 'Local end-state only: powershell -ExecutionPolicy Bypass -File .\scripts\test-windows-bootstrap-endstate.ps1' -ForegroundColor Yellow
  Write-Host 'Docs: docs/windows-bootstrap.md' -ForegroundColor Yellow
  exit 1
}
Write-Host "`nAll validation checks passed" -ForegroundColor Green
exit 0
