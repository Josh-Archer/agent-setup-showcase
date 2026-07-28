#Requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap agent definitions, skills, PowerShell profile env, and Homelab MCP clients (Windows).

.DESCRIPTION
  Mirrors scripts/setup_agents.sh:
  - Syncs agent/skill trees from this repo into ~/.codex, ~/.claude, ~/.gemini
  - Installs shell env loader for HOMELAB_MCP_API_KEY (no secrets in git)
  - Registers Paperless + Immich MCP for Codex, Grok, Gemini/Antigravity

.PARAMETER LoadKeyFromCluster
  Pull API key from kubectl secret into User env + local cache file.

.PARAMETER SkipEndStateCheck
  Skip the mandatory Windows end-state validation at the end of bootstrap.
  Prefer leaving this off; partial installs should fail non-zero.

.PARAMETER SkipMcpClients
  Skip MCP client registration (agents + hooks only). End-state MCP checks
  are skipped when this is set.
#>
[CmdletBinding()]
param(
  [switch]$LoadKeyFromCluster,
  [switch]$SkipMcpClients,
  [switch]$SkipEndStateCheck
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ConfigDir = Join-Path $env:USERPROFILE '.config\homelab'
$ShellSnippetSrc = Join-Path $RepoRoot 'shell\homelab-mcp.ps1'
$ShellSnippetDst = Join-Path $ConfigDir 'homelab-mcp.ps1'
$KeyCache = Join-Path $ConfigDir 'mcp-api-key'

function Write-Log([string]$Message) {
  Write-Host "[setup_agents] $Message"
}

function Sync-Tree {
  param([string]$Src, [string]$Dst)
  if (-not (Test-Path $Src)) { return }
  if (-not (Test-Path $Dst)) { New-Item -ItemType Directory -Path $Dst -Force | Out-Null }
  # Robocopy mirror agent defs (exclude secrets if any)
  & robocopy $Src $Dst /MIR /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
  $code = $LASTEXITCODE
  if ($code -ge 8) { throw "robocopy failed $Src -> $Dst (exit $code)" }
  Write-Log "synced $Src -> $Dst"
}

function Install-ShellSnippet {
  if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
  Copy-Item -Force $ShellSnippetSrc $ShellSnippetDst
  Write-Log "installed $ShellSnippetDst"

  $marker = '# >>> homelab-mcp (agent-setup-showcase) >>>'
  $endMarker = '# <<< homelab-mcp (agent-setup-showcase) <<<'
  $block = @"
$marker
# Homelab MCP env (Paperless/Immich). No secrets in this line.
. '$($ShellSnippetDst.Replace("'", "''"))'
$endMarker
"@

  $profiles = @(
    (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
  )
  foreach ($profilePath in $profiles) {
    $dir = Split-Path -Parent $profilePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Path $profilePath -Force | Out-Null }
    $content = Get-Content -Raw -Path $profilePath -ErrorAction SilentlyContinue
    if ($null -eq $content) { $content = '' }
    if ($content -match [regex]::Escape($marker)) {
      $content = [regex]::Replace($content, "(?ms)$([regex]::Escape($marker)).*?$([regex]::Escape($endMarker))\r?\n?", '')
    }
    $content = $content.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
    Set-Content -Path $profilePath -Value $content -Encoding UTF8
    Write-Log "ensured MCP hook in $profilePath"
  }
}

function Refresh-KeyCache {
  if ($LoadKeyFromCluster) {
    & (Join-Path $RepoRoot 'scripts\install-homelab-mcp.ps1') -LoadKeyFromCluster -SkipCodex -SkipGrok -SkipGemini
  }

  $key = $env:HOMELAB_MCP_API_KEY
  if ([string]::IsNullOrWhiteSpace($key)) {
    $key = [Environment]::GetEnvironmentVariable('HOMELAB_MCP_API_KEY', 'User')
  }
  if ([string]::IsNullOrWhiteSpace($key) -and (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    try {
      $b64 = kubectl -n mcp get secret paperless-mcp-secret -o jsonpath='{.data.API_KEY}' 2>$null
      if (-not [string]::IsNullOrWhiteSpace([string]$b64)) {
        $key = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$b64))
        [Environment]::SetEnvironmentVariable('HOMELAB_MCP_API_KEY', $key, 'User')
        $env:HOMELAB_MCP_API_KEY = $key
      }
    } catch {}
  }
  if (-not [string]::IsNullOrWhiteSpace($key)) {
    $env:HOMELAB_MCP_API_KEY = $key
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    # Allow current user write before replace (prior run may have set RO ACL)
    if (Test-Path -LiteralPath $KeyCache) {
      try {
        icacls $KeyCache /grant:r "${env:USERNAME}:(F)" 2>$null | Out-Null
      } catch {}
    }
    Set-Content -LiteralPath $KeyCache -Value $key -Encoding ascii -NoNewline
    try {
      icacls $KeyCache /inheritance:r 2>$null | Out-Null
      icacls $KeyCache /grant:r "${env:USERNAME}:(R,W)" 2>$null | Out-Null
    } catch {}
    Write-Log "key cache ready (length=$($key.Length), value not printed)"
  } else {
    Write-Warning 'HOMELAB_MCP_API_KEY not available; Paperless MCP auth may fail until set'
  }
}

Write-Log "repo=$RepoRoot"

try {
  Sync-Tree -Src (Join-Path $RepoRoot '.codex\agents') -Dst (Join-Path $env:USERPROFILE '.codex\agents')
  Sync-Tree -Src (Join-Path $RepoRoot '.claude\agents') -Dst (Join-Path $env:USERPROFILE '.claude\agents')
  Sync-Tree -Src (Join-Path $RepoRoot '.gemini\agents') -Dst (Join-Path $env:USERPROFILE '.gemini\agents')
  Sync-Tree -Src (Join-Path $RepoRoot '.gemini\skills') -Dst (Join-Path $env:USERPROFILE '.gemini\skills')

  Install-ShellSnippet
  Refresh-KeyCache

  if (-not $SkipMcpClients) {
    & (Join-Path $RepoRoot 'scripts\install-homelab-mcp.ps1')
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
      throw "install-homelab-mcp.ps1 failed with exit code $LASTEXITCODE"
    }
  }
} catch {
  Write-Host "[setup_agents] ERROR during bootstrap: $_" -ForegroundColor Red
  Write-Host '[setup_agents] Partial install detected. Re-run after fixing the error (install is idempotent).' -ForegroundColor Yellow
  Write-Host '[setup_agents] See docs/windows-bootstrap.md' -ForegroundColor Yellow
  exit 1
}

if (-not $SkipEndStateCheck) {
  Write-Log 'validating Windows end-state (agents, env hooks, MCP config)...'
  $endState = Join-Path $RepoRoot 'scripts\test-windows-bootstrap-endstate.ps1'
  if (-not (Test-Path -LiteralPath $endState)) {
    Write-Host "[setup_agents] ERROR: missing end-state script: $endState" -ForegroundColor Red
    exit 1
  }
  # Child process so the validator's `exit` does not abort this script early.
  if ($SkipMcpClients) {
    $psArgs = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $endState,
      '-RepoRoot', $RepoRoot, '-SkipMcpConfig', '-SkipRequireKey'
    )
  } else {
    $psArgs = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $endState,
      '-RepoRoot', $RepoRoot
    )
  }
  & powershell.exe @psArgs
  if ($LASTEXITCODE -ne 0) {
    Write-Host '[setup_agents] End-state validation failed (non-zero). Bootstrap is incomplete.' -ForegroundColor Red
    Write-Host '[setup_agents] Recovery: re-run this script (idempotent). See docs/windows-bootstrap.md' -ForegroundColor Yellow
    exit 1
  }
  Write-Log 'end-state validation passed'
} else {
  Write-Warning 'SkipEndStateCheck set; bootstrap did not verify agents/hooks/MCP end-state'
}

Write-Log 'done. Open a new terminal and restart Codex / Grok / Antigravity.'
exit 0
