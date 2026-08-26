#Requires -Version 5.1
<#
.SYNOPSIS
  Validate Homelab MCP config + connectivity without printing secrets.

.DESCRIPTION
  Checks client registration (Codex/Grok/Gemini/Antigravity), env presence,
  and probes Immich endpoint reachability with short timeouts so failures are
  actionable (never a silent handshake hang).

  Immich edge auth is LAN/Tailscale allowlist only (no Bearer key):
    192.168.0.0/16, 100.64.0.0/10, 127.0.0.1/32

.PARAMETER TimeoutSec
  HTTP probe timeout in seconds (default 5). Keep low to avoid hangs.

.PARAMETER SkipNetwork
  Skip client-side HTTP reachability probes (config/env/CLI checks only).

.PARAMETER SkipCluster
  Skip in-cluster kubectl health checks.
#>
[CmdletBinding()]
param(
  [ValidateRange(1, 60)]
  [int]$TimeoutSec = 5,
  [switch]$SkipNetwork,
  [switch]$SkipCluster
)

$ErrorActionPreference = 'Continue'
$failed = 0

function Ok([string]$m) { Write-Host "OK  $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "FAIL $m" -ForegroundColor Red; $script:failed++ }
function Info([string]$m) { Write-Host "INFO $m" -ForegroundColor Cyan }

# Load env from profile snippet if needed
$snip = Join-Path $env:USERPROFILE '.config\homelab\homelab-mcp.ps1'
if (Test-Path $snip) { . $snip }

if ([string]::IsNullOrWhiteSpace($env:HOMELAB_MCP_API_KEY)) {
  Bad 'HOMELAB_MCP_API_KEY is not set in this process (Paperless mcpo Bearer)'
} else {
  Ok "HOMELAB_MCP_API_KEY present (len=$($env:HOMELAB_MCP_API_KEY.Length))"
}

if ([string]::IsNullOrWhiteSpace($env:PAPERLESS_API_KEY)) {
  Info 'PAPERLESS_API_KEY not set (Grok stdio paperless MCP will fail until set)'
} else {
  Ok "PAPERLESS_API_KEY present (len=$($env:PAPERLESS_API_KEY.Length))"
}

# Config presence
foreach ($pair in @(
  @('codex paperless', (Select-String -Path "$env:USERPROFILE\.codex\config.toml" -Pattern 'mcp_servers\.paperless' -Quiet -ErrorAction SilentlyContinue)),
  @('codex immich', (Select-String -Path "$env:USERPROFILE\.codex\config.toml" -Pattern 'mcp_servers\.immich' -Quiet -ErrorAction SilentlyContinue)),
  @('grok paperless', (Select-String -Path "$env:USERPROFILE\.grok\config.toml" -Pattern 'mcp_servers\.paperless' -Quiet -ErrorAction SilentlyContinue)),
  @('grok immich', (Select-String -Path "$env:USERPROFILE\.grok\config.toml" -Pattern 'mcp_servers\.immich' -Quiet -ErrorAction SilentlyContinue))
)) {
  if ($pair[1]) { Ok $pair[0] } else { Bad "$($pair[0]) missing - re-run scripts/install-homelab-mcp.ps1 or setup_agents.ps1" }
}

try {
  $gs = Get-Content "$env:USERPROFILE\.gemini\settings.json" -Raw -ErrorAction Stop | ConvertFrom-Json
  if ($gs.mcpServers.paperless -and $gs.mcpServers.immich) { Ok 'gemini mcpServers (paperless+immich)' } else { Bad 'gemini mcpServers missing paperless and/or immich' }
} catch { Bad "gemini settings: $_" }

try {
  $agy = Get-Content "$env:USERPROFILE\.gemini\antigravity\mcp_config.json" -Raw -ErrorAction Stop | ConvertFrom-Json
  if ($agy.mcpServers.paperless -and $agy.mcpServers.immich) { Ok 'antigravity mcp_config (paperless+immich)' } else { Bad 'antigravity mcp_config missing paperless and/or immich' }
} catch { Bad "antigravity: $_" }

$ompCfg = "$env:USERPROFILE\.omp\agent\config.yml"
if (Test-Path $ompCfg) {
  try {
    $omp = Get-Content $ompCfg -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($omp.mcpServers.paperless -and $omp.mcpServers.immich) { Ok 'omp config (paperless+immich)' } else { Bad 'omp config missing paperless and/or immich' }
  } catch {
    # Check via regex/text fallback if yaml format
    $hasPl = Select-String -Path $ompCfg -Pattern 'paperless' -Quiet -ErrorAction SilentlyContinue
    $hasIm = Select-String -Path $ompCfg -Pattern 'immich' -Quiet -ErrorAction SilentlyContinue
    if ($hasPl -and $hasIm) { Ok 'omp config.yml (paperless+immich)' } else { Bad 'omp config.yml missing paperless/immich' }
  }
}

function Resolve-ImmichProbeTargets {
  <#
    Prefer hostname when DNS works; also offer Traefik Tailscale VIP + Host header
    so validate mirrors install-homelab-mcp.ps1 fallback behavior.
  #>
  $hostName = 'immich-mcp.archer.casa'
  $targets = @()
  $dnsOk = $false
  try {
    $addrs = [System.Net.Dns]::GetHostAddresses($hostName)
    if ($addrs -and $addrs.Count -gt 0) {
      $dnsOk = $true
      $ipList = ($addrs | ForEach-Object { $_.IPAddressToString }) -join ', '
      Ok "DNS $hostName -> $ipList"
      $targets += @{
        Label      = "http://$hostName"
        HealthUrl  = "http://$hostName/health"
        McpUrl     = "http://$hostName/mcp"
        HostHeader = $null
      }
    }
  } catch {
    Bad "DNS resolve failed for $hostName ($($_.Exception.Message)). On LAN use AdGuard rewrites or /etc/hosts; on remote join Tailscale and re-run setup_agents (hosts block) or set HOMELAB_TRAEFIK_TS_IP."
  }

  $tsVip = $env:HOMELAB_TRAEFIK_TS_IP
  if ([string]::IsNullOrWhiteSpace($tsVip)) { $tsVip = '100.68.151.94' }
  if (-not $dnsOk) {
    Info "Adding Tailscale Traefik fallback probe: $tsVip (Host: $hostName). Override with HOMELAB_TRAEFIK_TS_IP."
    $targets += @{
      Label      = "http://$tsVip (Host: $hostName)"
      HealthUrl  = "http://$tsVip/health"
      McpUrl     = "http://$tsVip/mcp"
      HostHeader = $hostName
    }
  }
  return ,$targets
}

function Invoke-TimedHttpGet {
  param(
    [Parameter(Mandatory)][string]$Uri,
    [int]$TimeoutSec = 5,
    [string]$HostHeader = $null,
    [hashtable]$Headers = $null
  )
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $result = [ordered]@{
    Ok         = $false
    StatusCode = $null
    Body       = ''
    Error      = $null
    TimedOut   = $false
    ElapsedMs  = 0
  }
  try {
    # HttpWebRequest gives reliable per-request timeouts on Windows PowerShell 5.1
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = 'GET'
    $req.Timeout = [Math]::Max(1, $TimeoutSec) * 1000
    $req.ReadWriteTimeout = [Math]::Max(1, $TimeoutSec) * 1000
    $req.AllowAutoRedirect = $true
    $req.UserAgent = 'agent-setup-validate-homelab-mcp/1.0'
    if ($HostHeader) { $req.Host = $HostHeader }
    if ($Headers) {
      foreach ($k in $Headers.Keys) {
        if ($k -ieq 'Authorization') {
          $req.Headers['Authorization'] = [string]$Headers[$k]
        } else {
          try { $req.Headers[$k] = [string]$Headers[$k] } catch { $req.Headers.Add($k, [string]$Headers[$k]) }
        }
      }
    }
    try {
      $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
      $ex = $_.Exception
      if ($ex.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
        $result.TimedOut = $true
        $result.Error = "timed out after ${TimeoutSec}s"
        return [pscustomobject]$result
      }
      if ($ex.Response) {
        $resp = $ex.Response
      } else {
        $result.Error = $ex.Message
        return [pscustomobject]$result
      }
    }
    try {
      $result.StatusCode = [int]$resp.StatusCode
      $stream = $resp.GetResponseStream()
      $reader = New-Object System.IO.StreamReader($stream)
      $body = $reader.ReadToEnd()
      $reader.Close()
      if ($body.Length -gt 200) { $body = $body.Substring(0, 200) }
      $result.Body = $body
      $result.Ok = ($result.StatusCode -ge 200 -and $result.StatusCode -lt 400)
    } finally {
      if ($resp) { $resp.Close() }
    }
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match 'timed out|Timeout|The operation has timed out') {
      $result.TimedOut = $true
      $result.Error = "timed out after ${TimeoutSec}s"
    } else {
      $result.Error = $msg
    }
  } finally {
    $sw.Stop()
    $result.ElapsedMs = [int]$sw.ElapsedMilliseconds
  }
  return [pscustomobject]$result
}

function Get-ImmichFailureHint {
  param(
    [pscustomobject]$Probe,
    [string]$Label
  )
  if ($Probe.TimedOut) {
    $lines = @(
      "Immich health probe timed out ($Label, ${TimeoutSec}s). This is the same class of hang MCP clients hit during streamable-HTTP handshake.",
      'Remediation:',
      '  1. Confirm you are on home LAN (192.168.0.0/16) or Tailscale (100.64.0.0/10).',
      '  2. Confirm DNS for immich-mcp.archer.casa (AdGuard / hosts / MagicDNS).',
      '  3. Re-run install with Tailscale VIP fallback (HOMELAB_TRAEFIK_TS_IP) if DNS is broken.',
      '  4. Do not wait on MCP handshake - fix network first, then re-run this validate script.'
    )
    return ($lines -join [Environment]::NewLine)
  }
  if ($null -ne $Probe.StatusCode -and $Probe.StatusCode -eq 403) {
    return "Immich returned HTTP 403 from $Label - source IP is outside the Traefik allowlist (LAN 192.168.0.0/16, Tailscale 100.64.0.0/10, loopback 127.0.0.1/32). Remediation: connect via Tailscale or home LAN; do not expose Immich MCP on a public entrypoint."
  }
  if ($null -ne $Probe.StatusCode -and $Probe.StatusCode -eq 404) {
    return "Immich returned 404 for $Label - host may be wrong or ingress path missing /health. Expected http://immich-mcp.archer.casa/health"
  }
  if ($Probe.Error -match 'actively refused|connection refused|No connection could be made') {
    return "Connection refused for $Label - Traefik/immich-mcp may be down. Check: kubectl -n mcp get deploy,po,svc,ingress -l app=immich-mcp"
  }
  if ($Probe.Error -match 'Name or service not known|No such host|could not be resolved|The remote name could not be resolved') {
    return "Hostname did not resolve for $Label. Fix DNS or use Tailscale VIP + Host header (see mcp/README.md)."
  }
  if ($Probe.Error) {
    return "Immich probe error for $Label : $($Probe.Error)"
  }
  return "Immich probe failed for $Label (HTTP $($Probe.StatusCode)). Body snippet: $($Probe.Body)"
}

function Test-ImmichClientReachability {
  param([int]$TimeoutSec = 5)

  Write-Host ''
  Info "Probing Immich MCP reachability (timeout=${TimeoutSec}s; no full MCP handshake)..."
  $targets = Resolve-ImmichProbeTargets
  if (-not $targets -or $targets.Count -eq 0) {
    Bad 'No Immich probe targets available (DNS failed and no fallback configured)'
    return
  }

  $anyHealthOk = $false
  foreach ($t in $targets) {
    $health = Invoke-TimedHttpGet -Uri $t.HealthUrl -TimeoutSec $TimeoutSec -HostHeader $t.HostHeader
    if ($health.Ok -and ("$($health.Body)" -match 'healthy|ok|UP|Healthy' -or $health.StatusCode -eq 200)) {
      Ok "immich /health via $($t.Label) (HTTP $($health.StatusCode), $($health.ElapsedMs)ms)"
      $anyHealthOk = $true
    } elseif ($health.Ok) {
      # 2xx without expected body - still treat as reachable
      Ok "immich /health via $($t.Label) reachable (HTTP $($health.StatusCode), $($health.ElapsedMs)ms); body did not match healthy (got: $($health.Body))"
      $anyHealthOk = $true
    } else {
      Bad (Get-ImmichFailureHint -Probe $health -Label "$($t.Label)/health")
    }

    # Light touch on /mcp: confirm path answers quickly. Do NOT perform MCP initialize
    # (that is what hangs clients). Any HTTP response within timeout proves routing.
    $mcp = Invoke-TimedHttpGet -Uri $t.McpUrl -TimeoutSec $TimeoutSec -HostHeader $t.HostHeader
    if ($mcp.TimedOut) {
      Bad (Get-ImmichFailureHint -Probe $mcp -Label "$($t.Label)/mcp")
    } elseif ($null -ne $mcp.StatusCode) {
      # 2xx/3xx/4xx/405/406 all prove the edge answered (not a hang)
      Ok "immich /mcp path answers via $($t.Label) (HTTP $($mcp.StatusCode), $($mcp.ElapsedMs)ms) - edge is reachable (no handshake attempted)"
    } elseif ($mcp.Error) {
      Bad (Get-ImmichFailureHint -Probe $mcp -Label "$($t.Label)/mcp")
    }
  }

  if (-not $anyHealthOk) {
    Info 'Immich client probe failed. In-cluster check (if kubectl works) can separate pod health from edge routing.'
  }
}

if (-not $SkipNetwork) {
  Test-ImmichClientReachability -TimeoutSec $TimeoutSec
} else {
  Info 'Skipping client-side network probes (-SkipNetwork)'
}

# In-cluster health (works even if DNS for archer.casa fails on this host)
if (-not $SkipCluster) {
  if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    Write-Host ''
    Info 'In-cluster smoke (kubectl)...'
    $immOut = ''
    $immErr = ''
    try {
      # --request-timeout bounds kubectl API hang; curl -m bounds in-pod HTTP hang
      $immOut = kubectl --request-timeout=15s -n mcp exec deploy/immich-mcp -- curl -sS -m 5 http://127.0.0.1:5000/health 2>&1 | Out-String
    } catch {
      $immErr = $_.Exception.Message
    }
    if ("$immOut" -match 'healthy') {
      Ok 'immich-mcp /health in-cluster'
    } else {
      $detail = if ($immOut) { $immOut.Trim() } else { $immErr }
      Bad "immich-mcp in-cluster health failed: $detail"
    }

    if (-not [string]::IsNullOrWhiteSpace($env:HOMELAB_MCP_API_KEY)) {
      $code = kubectl --request-timeout=30s -n mcp run "curl-pl-val-$([guid]::NewGuid().ToString('N').Substring(0,8))" --rm -i --restart=Never --image=curlimages/curl:8.5.0 --quiet -- `
        curl -sS -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $($env:HOMELAB_MCP_API_KEY)" `
        http://paperless-mcp.mcp.svc.cluster.local:8080/docs 2>$null
      if ("$code" -match '200') { Ok 'paperless-mcp /docs Bearer auth 200' } else { Bad "paperless-mcp auth code=$code" }
    }
  } else {
    Info 'kubectl not available; skipped in-cluster smoke'
  }
} else {
  Info 'Skipping in-cluster checks (-SkipCluster)'
}

# CLI lists
if (Get-Command codex -ErrorAction SilentlyContinue) {
  $list = codex mcp list 2>&1 | Out-String
  if ($list -match 'paperless' -and $list -match 'immich') { Ok 'codex mcp list has paperless+immich' } else { Bad 'codex mcp list missing paperless and/or immich' }
}
if (Get-Command grok -ErrorAction SilentlyContinue) {
  $list = grok mcp list 2>&1 | Out-String
  if ($list -match 'paperless' -and $list -match 'immich') { Ok 'grok mcp list has paperless+immich' } else { Bad 'grok mcp list missing paperless and/or immich' }
}

# Secret leakage quick audit of local configs (literal secrets only; env refs OK)
$scanFiles = @(
  "$env:USERPROFILE\.codex\config.toml",
  "$env:USERPROFILE\.grok\config.toml",
  "$env:USERPROFILE\.gemini\settings.json",
  "$env:USERPROFILE\.gemini\antigravity\mcp_config.json"
)
foreach ($f in $scanFiles) {
  if (-not (Test-Path $f)) { continue }
  $raw = Get-Content -Raw $f
  $hasEnvRef = ($raw.Contains('${HOMELAB_MCP_API_KEY}')) -or ($raw.Contains('bearer_token_env_var'))
  # Literal long Bearer token that is NOT an env placeholder
  $literalBearer = [regex]::Match($raw, 'Bearer\s+([A-Za-z0-9_\-]{20,})')
  if ($literalBearer.Success) {
    $tok = $literalBearer.Groups[1].Value
    if (-not $tok.StartsWith('${') -and -not $hasEnvRef) {
      Bad "possible secret in $f"
      continue
    }
  }
  Ok "no literal secrets in $f"
}

if ($failed -gt 0) {
  Write-Host "`n$failed check(s) failed" -ForegroundColor Red
  Write-Host 'See mcp/README.md (LAN/Tailscale allowlist + failure modes).' -ForegroundColor Yellow
  exit 1
}
Write-Host "`nAll validation checks passed" -ForegroundColor Green
exit 0
