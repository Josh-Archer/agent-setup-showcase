#Requires -Version 5.1
<#
.SYNOPSIS
  Install Paperless + Immich MCP servers into global Codex, Grok, and Antigravity/Gemini configs.

.DESCRIPTION
  - Never writes secret values into config files or this repo.
  - HOMELAB_MCP_API_KEY: mcpo Bearer for HTTP clients that speak OpenAPI-through-mcpo (not Grok native MCP).
  - PAPERLESS_API_KEY: Paperless-NGX token for Grok/Codex stdio paperless MCP (@baruchiro/paperless-mcp).
  - Immich: native HTTP MCP (allowlist only). Install uses hostname when DNS works, else Traefik Tailscale IP + Host.

.PARAMETER LoadKeyFromCluster
  Read paperless-mcp-secret API_KEY → HOMELAB_MCP_API_KEY and PAPERLESS_API_TOKEN → PAPERLESS_API_KEY.

.PARAMETER SkipCodex
.PARAMETER SkipGrok
.PARAMETER SkipGemini
  Skip installing for a specific client.
#>
[CmdletBinding()]
param(
  [switch]$LoadKeyFromCluster,
  [switch]$SkipCodex,
  [switch]$SkipGrok,
  [switch]$SkipGemini
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$FragDir = Join-Path $RepoRoot 'mcp\fragments'

function Test-EnvKey {
  $k = [Environment]::GetEnvironmentVariable('HOMELAB_MCP_API_KEY', 'Process')
  if ([string]::IsNullOrWhiteSpace($k)) {
    $k = [Environment]::GetEnvironmentVariable('HOMELAB_MCP_API_KEY', 'User')
  }
  if ([string]::IsNullOrWhiteSpace($k)) {
    return $false
  }
  $env:HOMELAB_MCP_API_KEY = $k
  return $true
}

function Import-KeyFromCluster {
  Write-Host 'Loading keys from cluster secret mcp/paperless-mcp-secret ...'
  $b64 = kubectl -n mcp get secret paperless-mcp-secret -o jsonpath='{.data.API_KEY}'
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($b64)) {
    throw 'Failed to read paperless-mcp-secret.API_KEY (is kubectl context set and secret present?)'
  }
  $key = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$b64))
  if ($key.Length -lt 8) { throw 'API_KEY from cluster looks empty/short' }
  [Environment]::SetEnvironmentVariable('HOMELAB_MCP_API_KEY', $key, 'User')
  $env:HOMELAB_MCP_API_KEY = $key
  Write-Host "Set User env HOMELAB_MCP_API_KEY (length=$($key.Length))."

  $tokB64 = kubectl -n mcp get secret paperless-mcp-secret -o jsonpath='{.data.PAPERLESS_API_TOKEN}'
  if (-not [string]::IsNullOrWhiteSpace([string]$tokB64)) {
    $tok = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$tokB64))
    if ($tok.Length -ge 8) {
      [Environment]::SetEnvironmentVariable('PAPERLESS_API_KEY', $tok, 'User')
      $env:PAPERLESS_API_KEY = $tok
      [Environment]::SetEnvironmentVariable('PAPERLESS_URL', 'https://paperless.archer.casa', 'User')
      $env:PAPERLESS_URL = 'https://paperless.archer.casa'
      Write-Host "Set User env PAPERLESS_API_KEY (length=$($tok.Length)) + PAPERLESS_URL."
    }
  } else {
    Write-Warning 'PAPERLESS_API_TOKEN missing from secret; Grok stdio paperless MCP will fail until set.'
  }
  Write-Host 'Restart agent apps so they pick up User env.'
}

function Test-PaperlessEnvKey {
  $k = [Environment]::GetEnvironmentVariable('PAPERLESS_API_KEY', 'Process')
  if ([string]::IsNullOrWhiteSpace($k)) {
    $k = [Environment]::GetEnvironmentVariable('PAPERLESS_API_KEY', 'User')
  }
  if ([string]::IsNullOrWhiteSpace($k)) { return $false }
  $env:PAPERLESS_API_KEY = $k
  return $true
}

function Resolve-ImmichMcpUrl {
  # Prefer DNS hostname; fall back to Traefik Tailscale VIP + Host header.
  $hostName = 'immich-mcp.archer.casa'
  try {
    $null = [System.Net.Dns]::GetHostAddresses($hostName)
    return @{ Url = "http://$hostName/mcp"; UseHostHeader = $false; HostHeader = $hostName }
  } catch {
    # NXDOMAIN / no resolution
  }
  $tsVip = $env:HOMELAB_TRAEFIK_TS_IP
  if ([string]::IsNullOrWhiteSpace($tsVip)) { $tsVip = '100.68.151.94' }
  Write-Warning "DNS for $hostName failed; using Tailscale Traefik $tsVip with Host header."
  return @{ Url = "http://$tsVip/mcp"; UseHostHeader = $true; HostHeader = $hostName }
}

function Merge-TomlFragment {
  param(
    [string]$TargetPath,
    [string]$FragmentPath,
    [string[]]$ServerNames
  )
  $frag = Get-Content -Raw -Path $FragmentPath
  $existing = if (Test-Path $TargetPath) { Get-Content -Raw -Path $TargetPath } else { '' }
  # Strip prior blocks for these servers so re-runs are idempotent
  foreach ($name in $ServerNames) {
    $pattern = "(?ms)^\[mcp_servers\.$([regex]::Escape($name))\](?:\r?\n(?!\[).*)*"
    $existing = [regex]::Replace($existing, $pattern, '')
    $patternEnv = "(?ms)^\[mcp_servers\.$([regex]::Escape($name))\.[^\]]+\](?:\r?\n(?!\[).*)*"
    $existing = [regex]::Replace($existing, $patternEnv, '')
  }
  $existing = $existing.TrimEnd() + "`n`n" + $frag.Trim() + "`n"
  $dir = Split-Path -Parent $TargetPath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  # backup
  if (Test-Path $TargetPath) {
    Copy-Item $TargetPath "$TargetPath.bak-homelab-mcp-$(Get-Date -Format yyyyMMddHHmmss)" -Force
  }
  [System.IO.File]::WriteAllText($TargetPath, $existing)
  Write-Host "Updated $TargetPath"
}

function Merge-JsonMcpServers {
  param(
    [string]$TargetPath,
    [string]$FragmentPath,
    [string]$RootKey  # empty = fragment is root mcpServers object; or 'mcpServers'
  )
  $fragObj = Get-Content -Raw $FragmentPath | ConvertFrom-Json
  $servers = if ($fragObj.mcpServers) { $fragObj.mcpServers } else { $fragObj }

  $target = [ordered]@{}
  if (Test-Path $TargetPath) {
    $raw = Get-Content -Raw $TargetPath
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $target = $raw | ConvertFrom-Json
    }
  } else {
    $dir = Split-Path -Parent $TargetPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  }

  if ($RootKey -eq 'mcpServers' -or $null -ne $target.mcpServers -or $TargetPath -match 'mcp_config') {
    if (-not $target.mcpServers) {
      $target | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $hash = @{}
    if ($target.mcpServers) {
      $target.mcpServers.PSObject.Properties | ForEach-Object { $hash[$_.Name] = $_.Value }
    }
    $servers.PSObject.Properties | ForEach-Object { $hash[$_.Name] = $_.Value }
    $target.mcpServers = [pscustomobject]$hash
  } else {
    # Gemini settings.json top-level mcpServers
    if (-not $target.mcpServers) {
      $target | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $hash = @{}
    if ($target.mcpServers) {
      $target.mcpServers.PSObject.Properties | ForEach-Object { $hash[$_.Name] = $_.Value }
    }
    $servers.PSObject.Properties | ForEach-Object { $hash[$_.Name] = $_.Value }
    $target.mcpServers = [pscustomobject]$hash
  }

  if (Test-Path $TargetPath) {
    Copy-Item $TargetPath "$TargetPath.bak-homelab-mcp-$(Get-Date -Format yyyyMMddHHmmss)" -Force
  }
  $json = $target | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText($TargetPath, $json)
  Write-Host "Updated $TargetPath"
}

if ($LoadKeyFromCluster) {
  Import-KeyFromCluster
}

if (-not (Test-EnvKey)) {
  Write-Warning @'
HOMELAB_MCP_API_KEY is not set. Paperless MCP will fail auth until you set it.
Re-run with -LoadKeyFromCluster or set the User env var from Vaultwarden/cluster.
'@
} else {
  Write-Host "HOMELAB_MCP_API_KEY is present (length=$($env:HOMELAB_MCP_API_KEY.Length))."
}

$names = @('paperless', 'immich')

$immich = Resolve-ImmichMcpUrl

if (-not $SkipCodex) {
  # Prefer CLI when available (writes bearer_token_env_var cleanly)
  if (Get-Command codex -ErrorAction SilentlyContinue) {
    Write-Host 'Installing Codex MCP servers via CLI...'
    try { & codex mcp remove paperless 2>&1 | Out-Null } catch {}
    try { & codex mcp remove immich 2>&1 | Out-Null } catch {}
    & codex mcp add paperless --url 'http://paperless-mcp.archer.casa' --bearer-token-env-var HOMELAB_MCP_API_KEY
    if ($LASTEXITCODE -ne 0) { throw "codex mcp add paperless failed ($LASTEXITCODE)" }
    # Immich is first-class alongside Paperless (native HTTP MCP, allowlist only).
    if ($immich.UseHostHeader) {
      # Some Codex builds accept --header; if not, fall back to plain URL and document Host need.
      & codex mcp add immich --url $immich.Url 2>$null
      if ($LASTEXITCODE -ne 0) {
        & codex mcp add immich --url $immich.Url
      }
      Write-Warning "Codex Immich uses $($immich.Url); ensure Host: $($immich.HostHeader) is sent if the client supports headers."
    } else {
      & codex mcp add immich --url $immich.Url
    }
    if ($LASTEXITCODE -ne 0) { throw "codex mcp add immich failed ($LASTEXITCODE)" }
    Write-Host 'Codex MCP servers registered (paperless+immich).'
  } else {
    Merge-TomlFragment -TargetPath (Join-Path $env:USERPROFILE '.codex\config.toml') `
      -FragmentPath (Join-Path $FragDir 'codex.homelab-mcp.toml') -ServerNames $names
    if ($immich.UseHostHeader) {
      # Patch Immich URL when DNS is broken (mirror Grok fallback).
      $cfg = Join-Path $env:USERPROFILE '.codex\config.toml'
      $raw = Get-Content -Raw $cfg
      $raw = $raw -replace 'url = "http://immich-mcp\.archer\.casa/mcp"', ("url = `"{0}`"" -f $immich.Url)
      if ($raw -notmatch '\[mcp_servers\.immich\.http_headers\]' -and $raw -notmatch '\[mcp_servers\.immich\.headers\]') {
        $raw = $raw.TrimEnd() + "`n`n[mcp_servers.immich.http_headers]`nHost = `"$($immich.HostHeader)`"`n"
      }
      [System.IO.File]::WriteAllText($cfg, $raw)
    }
  }
}

if (-not $SkipGrok) {
  if (-not (Test-PaperlessEnvKey)) {
    Write-Warning 'PAPERLESS_API_KEY not set; Grok paperless stdio MCP will fail auth until set (re-run -LoadKeyFromCluster).'
  }
  if (Get-Command grok -ErrorAction SilentlyContinue) {
    Write-Host 'Installing Grok MCP servers via CLI...'
    try { & grok mcp remove paperless 2>&1 | Out-Null } catch {}
    try { & grok mcp remove immich 2>&1 | Out-Null } catch {}
    # Paperless: native stdio MCP (cluster mcpo is OpenAPI, not streamable HTTP MCP)
    if ($env:PAPERLESS_URL) {
      & grok mcp add paperless -e "PAPERLESS_URL=$env:PAPERLESS_URL" -e 'PAPERLESS_API_KEY=${PAPERLESS_API_KEY}' -e "PAPERLESS_PUBLIC_URL=$env:PAPERLESS_URL" -- npx -y @baruchiro/paperless-mcp@latest
    } else {
      & grok mcp add paperless -e 'PAPERLESS_URL=https://paperless.archer.casa' -e 'PAPERLESS_API_KEY=${PAPERLESS_API_KEY}' -e 'PAPERLESS_PUBLIC_URL=https://paperless.archer.casa' -- npx -y @baruchiro/paperless-mcp@latest
    }
    if ($LASTEXITCODE -ne 0) { throw "grok mcp add paperless failed ($LASTEXITCODE)" }
    if ($immich.UseHostHeader) {
      & grok mcp add --transport http immich $immich.Url --header "Host: $($immich.HostHeader)"
    } else {
      & grok mcp add --transport http immich $immich.Url
    }
    if ($LASTEXITCODE -ne 0) { throw "grok mcp add immich failed ($LASTEXITCODE)" }
    Write-Host 'Grok MCP servers registered (paperless=stdio, immich=http).'
  } else {
    Merge-TomlFragment -TargetPath (Join-Path $env:USERPROFILE '.grok\config.toml') `
      -FragmentPath (Join-Path $FragDir 'grok.homelab-mcp.toml') -ServerNames $names
    if ($immich.UseHostHeader) {
      # Patch immich URL/header when DNS is broken
      $cfg = Join-Path $env:USERPROFILE '.grok\config.toml'
      $raw = Get-Content -Raw $cfg
      $raw = $raw -replace 'url = "http://immich-mcp\.archer\.casa/mcp"', ("url = `"{0}`"" -f $immich.Url)
      if ($raw -notmatch '\[mcp_servers\.immich\.headers\]') {
        $raw = $raw.TrimEnd() + "`n`n[mcp_servers.immich.headers]`nHost = `"$($immich.HostHeader)`"`n"
      }
      [System.IO.File]::WriteAllText($cfg, $raw)
    }
  }
}

if (-not $SkipGemini) {
  Merge-JsonMcpServers -TargetPath (Join-Path $env:USERPROFILE '.gemini\settings.json') `
    -FragmentPath (Join-Path $FragDir 'gemini.mcpServers.json') -RootKey 'mcpServers'
  Merge-JsonMcpServers -TargetPath (Join-Path $env:USERPROFILE '.gemini\antigravity\mcp_config.json') `
    -FragmentPath (Join-Path $FragDir 'antigravity.mcp_config.json') -RootKey 'mcpServers'
  # Enable in mcp-server-enablement if file exists
  $enablePath = Join-Path $env:USERPROFILE '.gemini\mcp-server-enablement.json'
  if (Test-Path $enablePath) {
    try {
      $en = Get-Content -Raw $enablePath | ConvertFrom-Json
      $en | Add-Member -NotePropertyName paperless -NotePropertyValue @{ enabled = $true } -Force
      $en | Add-Member -NotePropertyName immich -NotePropertyValue @{ enabled = $true } -Force
      # ConvertTo-Json may flatten oddly; rewrite carefully
      $hash = @{}
      $en.PSObject.Properties | ForEach-Object {
        if ($_.Name -in @('paperless', 'immich')) {
          $hash[$_.Name] = @{ enabled = $true }
        } else {
          $hash[$_.Name] = $_.Value
        }
      }
      $hash['paperless'] = @{ enabled = $true }
      $hash['immich'] = @{ enabled = $true }
      Copy-Item $enablePath "$enablePath.bak-homelab-mcp-$(Get-Date -Format yyyyMMddHHmmss)" -Force
      ($hash | ConvertTo-Json -Depth 10) | Set-Content -Path $enablePath -Encoding utf8
      Write-Host "Updated $enablePath"
    } catch {
      Write-Warning "Could not update mcp-server-enablement.json: $_"
    }
  }
}

Write-Host ''
Write-Host 'Done. Restart Codex / Grok / Antigravity (agy) so they reload MCP config and User env.'
Write-Host 'Immich registered for supported clients (Codex / Grok / Gemini / Antigravity).'
Write-Host 'Smoke (from LAN/Tailscale allowlist — never hangs if you use -m/--max-time):'
Write-Host '  curl -sS -m 5 -o NUL -w "%{http_code}" -H "Authorization: Bearer $env:HOMELAB_MCP_API_KEY" http://paperless-mcp.archer.casa/docs'
Write-Host '  curl -sS -m 5 http://immich-mcp.archer.casa/health'
Write-Host 'Validate (timed Immich probe + config checks):'
Write-Host '  powershell -ExecutionPolicy Bypass -File .\scripts\validate-homelab-mcp.ps1'
