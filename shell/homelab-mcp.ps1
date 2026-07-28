# Homelab MCP env bootstrap for Windows PowerShell profiles.
# - Never prints secret values
# - Loads HOMELAB_MCP_API_KEY (mcpo Bearer) and PAPERLESS_API_KEY (Paperless-NGX token for stdio MCP)
#
# Installed by scripts/setup_agents.ps1 into the user profile as:
#   . "$HOME\.config\homelab\homelab-mcp.ps1"
#
# Secret load precedence (highest → lowest) — see scripts/homelab_mcp_secret_load.py
# and mcp/README.md:
#   1. process environment
#   2. user environment (Windows User scope)
#   3. live kubectl secret (cluster source of truth; refreshes cache + User env)
#   4. local cache file (offline fallback only; may warn)
#
# Fail-loud: missing keys and rejected probes Write-Warning (no silent stale cache).
# Optional probe: $env:HOMELAB_MCP_KEY_PROBE = '1' and optional HOMELAB_MCP_KEY_PROBE_URL.

function Write-HomelabMcpWarn {
  param([Parameter(Mandatory)][string]$Message)
  Write-Warning "[homelab-mcp] $Message"
}

function Test-HomelabMcpKeyProbe {
  param([Parameter(Mandatory)][string]$Key)
  $flag = $env:HOMELAB_MCP_KEY_PROBE
  if ([string]::IsNullOrWhiteSpace($flag)) { return $true }
  if ($flag -notin @('1', 'true', 'TRUE', 'yes', 'YES')) { return $true }

  $url = $env:HOMELAB_MCP_KEY_PROBE_URL
  if ([string]::IsNullOrWhiteSpace($url)) {
    $url = 'http://paperless-mcp.archer.casa/docs'
  }
  try {
    $headers = @{ Authorization = "Bearer $Key"; 'User-Agent' = 'homelab-mcp-secret-load/1' }
    $resp = Invoke-WebRequest -Uri $url -Headers $headers -Method GET -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
    if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) { return $true }
    Write-HomelabMcpWarn "probe failed for candidate (HTTP $($resp.StatusCode)); trying next source"
    return $false
  } catch {
    Write-HomelabMcpWarn "probe failed for candidate ($($_.Exception.GetType().Name)); trying next source"
    return $false
  }
}

function Save-HomelabMcpCache {
  param(
    [Parameter(Mandatory)][string]$CacheFile,
    [Parameter(Mandatory)][string]$Key
  )
  $dir = Split-Path -Parent $CacheFile
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (Test-Path -LiteralPath $CacheFile) {
    try { icacls $CacheFile /grant:r "${env:USERNAME}:(F)" 2>$null | Out-Null } catch {}
  }
  Set-Content -LiteralPath $CacheFile -Value $Key -Encoding ascii -NoNewline
  try {
    icacls $CacheFile /inheritance:r 2>$null | Out-Null
    icacls $CacheFile /grant:r "${env:USERNAME}:(R,W)" 2>$null | Out-Null
  } catch {}
}

function Get-HomelabMcpFromKubectl {
  param([Parameter(Mandatory)][string]$KubectlJsonPath)
  if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { return $null }
  try {
    $b64 = kubectl -n mcp get secret paperless-mcp-secret -o jsonpath=$KubectlJsonPath 2>$null
    if ([string]::IsNullOrWhiteSpace([string]$b64)) { return $null }
    $key = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$b64)).Trim()
    if ($key.Length -lt 8) { return $null }
    return $key
  } catch {
    return $null
  }
}

function Import-HomelabEnvVar {
  param(
    [Parameter(Mandatory)][string]$Name,
    [string]$CacheFile,
    [string]$KubectlJsonPath
  )
  $kubectlAvailable = [bool](Get-Command kubectl -ErrorAction SilentlyContinue)

  # 1) process env
  $cur = [Environment]::GetEnvironmentVariable($Name, 'Process')
  if (-not [string]::IsNullOrWhiteSpace($cur) -and $cur.Trim().Length -ge 8) {
    $cur = $cur.Trim()
    if (Test-HomelabMcpKeyProbe -Key $cur) {
      Set-Item -Path "Env:$Name" -Value $cur
      return
    }
    Write-HomelabMcpWarn "$Name`: process env key rejected by probe"
    Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
  }

  # 2) user env
  $userKey = [Environment]::GetEnvironmentVariable($Name, 'User')
  if (-not [string]::IsNullOrWhiteSpace($userKey) -and $userKey.Trim().Length -ge 8) {
    $userKey = $userKey.Trim()
    if (Test-HomelabMcpKeyProbe -Key $userKey) {
      Set-Item -Path "Env:$Name" -Value $userKey
      return
    }
    Write-HomelabMcpWarn "$Name`: user env key rejected by probe"
  }

  # 3) live kubectl BEFORE cache (refuse silent stale cache) — issue #14
  if ($kubectlAvailable -and $KubectlJsonPath) {
    $kKey = Get-HomelabMcpFromKubectl -KubectlJsonPath $KubectlJsonPath
    if (-not [string]::IsNullOrWhiteSpace($kKey)) {
      if (Test-HomelabMcpKeyProbe -Key $kKey) {
        Set-Item -Path "Env:$Name" -Value $kKey
        [Environment]::SetEnvironmentVariable($Name, $kKey, 'User')
        if ($CacheFile) {
          if (Test-Path -LiteralPath $CacheFile) {
            try {
              $old = (Get-Content -LiteralPath $CacheFile -Raw -ErrorAction SilentlyContinue)
              if ($old -and $old.Trim() -ne $kKey) {
                Write-HomelabMcpWarn "$Name`: cache differed from live kubectl secret; refreshing cache"
              }
            } catch {}
          }
          Save-HomelabMcpCache -CacheFile $CacheFile -Key $kKey
        }
        return
      }
      Write-HomelabMcpWarn "$Name`: kubectl key rejected by probe"
    }
  }

  # 4) cache file (offline fallback)
  if ($CacheFile -and (Test-Path -LiteralPath $CacheFile)) {
    try {
      $key = (Get-Content -LiteralPath $CacheFile -Raw -ErrorAction Stop).Trim()
      if ($key.Length -ge 8) {
        if (Test-HomelabMcpKeyProbe -Key $key) {
          Set-Item -Path "Env:$Name" -Value $key
          if ($kubectlAvailable) {
            Write-HomelabMcpWarn "$Name`: using cache while kubectl returned no key; cache may be stale"
          } else {
            Write-HomelabMcpWarn "$Name`: using local cache (kubectl unavailable); key not revalidated"
          }
          return
        }
        Write-HomelabMcpWarn "$Name`: cache key rejected by probe"
      }
    } catch {}
  }

  Write-HomelabMcpWarn "$Name`: no usable key from process/user/kubectl/cache; MCP auth will fail until set"
}

$configDir = Join-Path $env:USERPROFILE '.config\homelab'
Import-HomelabEnvVar -Name 'HOMELAB_MCP_API_KEY' `
  -CacheFile (Join-Path $configDir 'mcp-api-key') `
  -KubectlJsonPath '{.data.API_KEY}'
Import-HomelabEnvVar -Name 'PAPERLESS_API_KEY' `
  -CacheFile (Join-Path $configDir 'paperless-api-key') `
  -KubectlJsonPath '{.data.PAPERLESS_API_TOKEN}'
if ([string]::IsNullOrWhiteSpace($env:PAPERLESS_URL)) {
  $pu = [Environment]::GetEnvironmentVariable('PAPERLESS_URL', 'User')
  if ([string]::IsNullOrWhiteSpace($pu)) { $pu = 'https://paperless.archer.casa' }
  $env:PAPERLESS_URL = $pu
}
