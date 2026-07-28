#Requires -Version 5.1
<#
.SYNOPSIS
  Validate Windows agent-setup bootstrap end-state (local checks only).

.DESCRIPTION
  Confirms agents, PowerShell env hooks, and MCP client config are present
  after scripts/setup_agents.ps1. Does not print secret values. Does not
  require kubectl or live cluster connectivity (those stay in
  validate-homelab-mcp.ps1).

  Exit 0 on full success. Exit 1 on any missing step, with an actionable
  recovery message pointing at the failed check.

.PARAMETER RepoRoot
  Optional path to the agent-setup repo (defaults to parent of scripts/).

.PARAMETER SkipOptionalClients
  When set, do not run Codex/Grok CLI `mcp list` checks even if the CLIs
  are on PATH. Config-file checks still run unless -SkipMcpConfig.

.PARAMETER SkipMcpConfig
  Skip MCP client config checks (use when setup was run with -SkipMcpClients).

.PARAMETER SkipRequireKey
  Do not fail when HOMELAB_MCP_API_KEY is missing (soft check only).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\test-windows-bootstrap-endstate.ps1
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [switch]$SkipOptionalClients,
  [switch]$SkipMcpConfig,
  [switch]$SkipRequireKey
)

$ErrorActionPreference = 'Continue'
$failed = New-Object System.Collections.Generic.List[string]
$script:checksPassed = 0
$script:checksFailed = 0

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$ConfigDir = Join-Path $env:USERPROFILE '.config\homelab'
$ShellSnippetDst = Join-Path $ConfigDir 'homelab-mcp.ps1'
$KeyCache = Join-Path $ConfigDir 'mcp-api-key'
$Marker = '# >>> homelab-mcp (agent-setup-showcase) >>>'
$EndMarker = '# <<< homelab-mcp (agent-setup-showcase) <<<'

function Ok([string]$Message) {
  Write-Host "OK   $Message" -ForegroundColor Green
  $script:checksPassed++
}

function Fail([string]$Step, [string]$Message, [string]$Recovery) {
  Write-Host "FAIL [$Step] $Message" -ForegroundColor Red
  if (-not [string]::IsNullOrWhiteSpace($Recovery)) {
    Write-Host "     -> $Recovery" -ForegroundColor Yellow
  }
  $script:checksFailed++
  $failed.Add("${Step}: ${Message}") | Out-Null
}

function Test-TomlServers {
  param(
    [string]$Path,
    [string[]]$Names,
    [string]$Label
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    Fail $Label "missing config file: $Path" `
      "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1"
    return
  }
  $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($raw)) {
    Fail $Label "empty config: $Path" `
      "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\install-homelab-mcp.ps1"
    return
  }
  $missing = @()
  foreach ($n in $Names) {
    if ($raw -notmatch [regex]::Escape("mcp_servers.$n")) {
      $missing += $n
    }
  }
  if ($missing.Count -gt 0) {
    Fail $Label "missing MCP server entries: $($missing -join ', ') in $Path" `
      "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\install-homelab-mcp.ps1"
  } else {
    Ok "$Label has $($Names -join '+')"
  }
}

function Test-JsonMcpServers {
  param(
    [string]$Path,
    [string]$Label
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    Fail $Label "missing config file: $Path" `
      "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\install-homelab-mcp.ps1"
    return
  }
  try {
    $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $servers = $doc.mcpServers
    if (-not $servers) {
      Fail $Label "no mcpServers object in $Path" `
        "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\install-homelab-mcp.ps1"
      return
    }
    $hasPaperless = $null -ne $servers.paperless
    $hasImmich = $null -ne $servers.immich
    if ($hasPaperless -and $hasImmich) {
      Ok "$Label mcpServers paperless+immich"
    } else {
      $miss = @()
      if (-not $hasPaperless) { $miss += 'paperless' }
      if (-not $hasImmich) { $miss += 'immich' }
      Fail $Label "missing mcpServers: $($miss -join ', ') in $Path" `
        "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\install-homelab-mcp.ps1"
    }
  } catch {
    Fail $Label "invalid JSON in $Path : $_" `
      "Fix or delete the file, then re-run install-homelab-mcp.ps1"
  }
}

Write-Host "=== Windows bootstrap end-state ===" -ForegroundColor Cyan
Write-Host "repo=$RepoRoot"
Write-Host "user=$env:USERPROFILE"
Write-Host ''

# --- 1) Agents present ---
Write-Host '-- agents --' -ForegroundColor Cyan
$agentTrees = @(
  @{ Step = 'agents.codex'; Src = (Join-Path $RepoRoot '.codex\agents'); Dst = (Join-Path $env:USERPROFILE '.codex\agents'); Pattern = '*.agent.md' },
  @{ Step = 'agents.claude'; Src = (Join-Path $RepoRoot '.claude\agents'); Dst = (Join-Path $env:USERPROFILE '.claude\agents'); Pattern = '*.md' },
  @{ Step = 'agents.gemini'; Src = (Join-Path $RepoRoot '.gemini\agents'); Dst = (Join-Path $env:USERPROFILE '.gemini\agents'); Pattern = '*.md' }
)
foreach ($t in $agentTrees) {
  if (-not (Test-Path -LiteralPath $t.Src)) {
    Fail $t.Step "repo source missing: $($t.Src)" `
      "Clone/checkout agent-setup with agent trees, then re-run setup_agents.ps1"
    continue
  }
  if (-not (Test-Path -LiteralPath $t.Dst)) {
    Fail $t.Step "destination missing: $($t.Dst)" `
      "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1"
    continue
  }
  $srcCount = @(Get-ChildItem -LiteralPath $t.Src -File -Filter $t.Pattern -ErrorAction SilentlyContinue).Count
  $dstCount = @(Get-ChildItem -LiteralPath $t.Dst -File -Filter $t.Pattern -ErrorAction SilentlyContinue).Count
  if ($srcCount -lt 1) {
    Fail $t.Step "repo has no files matching $($t.Pattern) under $($t.Src)" `
      "Restore agent definitions in the repo, then re-run setup_agents.ps1"
    continue
  }
  if ($dstCount -lt 1) {
    Fail $t.Step "no installed agent files in $($t.Dst)" `
      "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1"
    continue
  }
  if ($dstCount -lt $srcCount) {
    Fail $t.Step "partial agent sync: installed $dstCount / repo $srcCount under $($t.Dst)" `
      "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1 (robocopy mirror)"
  } else {
    Ok "$($t.Step) installed ($dstCount files)"
  }
}

# --- 2) Env hooks ---
Write-Host ''
Write-Host '-- env hooks --' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $ShellSnippetDst)) {
  Fail 'hooks.snippet' "missing shell snippet: $ShellSnippetDst" `
    "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1"
} else {
  Ok "shell snippet present ($ShellSnippetDst)"
}

$profiles = @(
  (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
  (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
)
$hooked = 0
foreach ($profilePath in $profiles) {
  if (-not (Test-Path -LiteralPath $profilePath)) {
    Fail 'hooks.profile' "profile missing: $profilePath" `
      "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1"
    continue
  }
  $content = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
  if ($null -eq $content) { $content = '' }
  $hasStart = $content.Contains($Marker)
  $hasEnd = $content.Contains($EndMarker)
  $refsSnippet = $content -match [regex]::Escape($ShellSnippetDst) -or $content -match 'homelab-mcp\.ps1'
  if ($hasStart -and $hasEnd -and $refsSnippet) {
    Ok "profile hook: $profilePath"
    $hooked++
  } else {
    $detail = @()
    if (-not $hasStart) { $detail += 'missing start marker' }
    if (-not $hasEnd) { $detail += 'missing end marker' }
    if (-not $refsSnippet) { $detail += 'does not source homelab-mcp.ps1' }
    Fail 'hooks.profile' "$profilePath : $($detail -join '; ')" `
      "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1 (idempotent profile block)"
  }
}
if ($hooked -eq 0) {
  # already failed per-profile; ensure recovery is clear
}

# --- 3) MCP config ---
Write-Host ''
Write-Host '-- MCP config --' -ForegroundColor Cyan
if ($SkipMcpConfig) {
  Write-Host 'SKIP MCP config checks (-SkipMcpConfig)' -ForegroundColor Yellow
} else {
  Test-TomlServers -Path (Join-Path $env:USERPROFILE '.codex\config.toml') `
    -Names @('paperless', 'immich') -Label 'mcp.codex'
  Test-TomlServers -Path (Join-Path $env:USERPROFILE '.grok\config.toml') `
    -Names @('paperless', 'immich') -Label 'mcp.grok'
  Test-JsonMcpServers -Path (Join-Path $env:USERPROFILE '.gemini\settings.json') `
    -Label 'mcp.gemini'
  Test-JsonMcpServers -Path (Join-Path $env:USERPROFILE '.gemini\antigravity\mcp_config.json') `
    -Label 'mcp.antigravity'

  if (-not $SkipOptionalClients) {
    if (Get-Command codex -ErrorAction SilentlyContinue) {
      $list = & codex mcp list 2>&1 | Out-String
      if ($list -match 'paperless' -and $list -match 'immich') {
        Ok 'codex mcp list has paperless+immich'
      } else {
        Fail 'mcp.codex.cli' 'codex mcp list missing paperless and/or immich' `
          "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\install-homelab-mcp.ps1"
      }
    } else {
      Ok 'codex CLI not on PATH (config-file check is authoritative)'
    }
    if (Get-Command grok -ErrorAction SilentlyContinue) {
      $list = & grok mcp list 2>&1 | Out-String
      if ($list -match 'paperless' -and $list -match 'immich') {
        Ok 'grok mcp list has paperless+immich'
      } else {
        Fail 'mcp.grok.cli' 'grok mcp list missing paperless and/or immich' `
          "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\install-homelab-mcp.ps1"
      }
    } else {
      Ok 'grok CLI not on PATH (config-file check is authoritative)'
    }
  }
}

# --- 4) Key presence (no value printed) ---
Write-Host ''
Write-Host '-- secrets presence (no values) --' -ForegroundColor Cyan
$key = $env:HOMELAB_MCP_API_KEY
if ([string]::IsNullOrWhiteSpace($key)) {
  $key = [Environment]::GetEnvironmentVariable('HOMELAB_MCP_API_KEY', 'User')
}
if ([string]::IsNullOrWhiteSpace($key) -and (Test-Path -LiteralPath $KeyCache)) {
  try {
    $key = (Get-Content -LiteralPath $KeyCache -Raw -ErrorAction Stop).Trim()
  } catch {}
}
if (-not [string]::IsNullOrWhiteSpace($key) -and $key.Length -ge 8) {
  Ok "HOMELAB_MCP_API_KEY available (length=$($key.Length))"
} elseif (-not $SkipRequireKey) {
  Fail 'env.key' 'HOMELAB_MCP_API_KEY not set (process, User env, or cache)' `
    "Re-run: powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1 -LoadKeyFromCluster"
} else {
  Write-Host "WARN env.key: HOMELAB_MCP_API_KEY not set (soft)" -ForegroundColor Yellow
}

# --- Summary ---
Write-Host ''
if ($script:checksFailed -gt 0) {
  Write-Host "Windows bootstrap end-state FAILED: $($script:checksFailed) check(s) failed, $($script:checksPassed) passed." -ForegroundColor Red
  Write-Host ''
  Write-Host 'Recovery (safe to re-run; install steps are idempotent):' -ForegroundColor Yellow
  Write-Host '  1. cd <agent-setup-repo>'
  Write-Host '  2. powershell -ExecutionPolicy Bypass -File .\scripts\setup_agents.ps1 -LoadKeyFromCluster'
  Write-Host '  3. powershell -ExecutionPolicy Bypass -File .\scripts\test-windows-bootstrap-endstate.ps1'
  Write-Host ''
  Write-Host 'Failed steps:' -ForegroundColor Yellow
  foreach ($f in $failed) {
    Write-Host "  - $f"
  }
  Write-Host ''
  Write-Host 'See docs/windows-bootstrap.md for partial-failure recovery.' -ForegroundColor Yellow
  exit 1
}

Write-Host "Windows bootstrap end-state OK: $($script:checksPassed) check(s) passed." -ForegroundColor Green
exit 0
