<#
.SYNOPSIS
  Merge Vesper's hooks into an existing .claude/settings.json.

.DESCRIPTION
  Vesper's return leg lives in a SessionStart hook, not in the skill folder. Installing
  the skill without this step gives you a Vesper whose departure leg works and whose
  return leg does not exist.

  /vesper setup offers to run this for you; this script exists for the times it did
  not, or when you are pointing Vesper at a second repo.

  This script exists instead of "paste the snippet in" because settings.json is the one
  file whose corruption is both silent and total: a parse error disables every hook AND
  every permission rule already present, with no error surfaced at session start.

  It is idempotent. If a Vesper hook is already present it is left ALONE rather than
  overwritten - you are expected to edit the PostToolUse project regex after install,
  and a re-run must never silently discard that edit.

.EXAMPLE
  pwsh ~/.claude/skills/vesper/scripts/Merge-VesperHooks.ps1
  pwsh ~/.claude/skills/vesper/scripts/Merge-VesperHooks.ps1 -SettingsPath "<repo>/.claude/settings.json" -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SettingsPath,
    [string]$SnippetPath = (Join-Path $PSScriptRoot 'settings-snippet.json')
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ required (this script uses ConvertFrom-Json -AsHashtable). Current: $($PSVersionTable.PSVersion)"
}

# Default the target to .claude/settings.json at the current repo root.
if (-not $SettingsPath) {
    $root = git rev-parse --show-toplevel 2>$null | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Not inside a git repository, and -SettingsPath was not supplied. Pass the path explicitly."
    }
    $SettingsPath = Join-Path $root '.claude/settings.json'
}

if (-not (Test-Path -LiteralPath $SnippetPath)) {
    throw "Snippet not found: $SnippetPath"
}

# --- Load the snippet -------------------------------------------------------
try {
    $snippet = Get-Content -LiteralPath $SnippetPath -Raw | ConvertFrom-Json -AsHashtable
} catch {
    throw "Snippet is not valid JSON: $SnippetPath - $($_.Exception.Message)"
}

# --- Load the target, or start a fresh one ----------------------------------
$settings = $null
$isNew    = $false
if (Test-Path -LiteralPath $SettingsPath) {
    $raw = Get-Content -LiteralPath $SettingsPath -Raw
    try {
        $settings = $raw | ConvertFrom-Json -AsHashtable
    } catch {
        # Refuse to touch a file we cannot parse. Overwriting it would destroy
        # whatever the user already had, which is the exact failure this script exists
        # to prevent.
        throw "Refusing to merge: '$SettingsPath' is not valid JSON ($($_.Exception.Message)). Fix or move it first - merging would discard its current contents."
    }
    if ($null -eq $settings) { $settings = @{} }
} else {
    $settings = @{}
    $isNew    = $true
    $parent   = Split-Path -Parent $SettingsPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

$added   = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()

# --- Merge permissions.allow (dedupe by exact string) -----------------------
if ($snippet.ContainsKey('permissions') -and $snippet.permissions.ContainsKey('allow')) {
    if (-not $settings.ContainsKey('permissions'))          { $settings['permissions'] = @{} }
    if (-not $settings.permissions.ContainsKey('allow'))    { $settings.permissions['allow'] = @() }

    $existing = @($settings.permissions.allow)
    foreach ($rule in $snippet.permissions.allow) {
        if ($existing -contains $rule) {
            $skipped.Add("permission already present: $rule")
        } else {
            $existing += $rule
            $added.Add("permission: $rule")
        }
    }
    $settings.permissions['allow'] = $existing
}

# --- Merge hooks ------------------------------------------------------------
# Idempotency key: a hook is "already Vesper's" if its command mentions the handoff
# file. That token appears in both hooks and in nothing else.
function Test-VesperHookPresent {
    param($EventArray)
    foreach ($matcherBlock in @($EventArray)) {
        foreach ($h in @($matcherBlock.hooks)) {
            if ($h.command -and $h.command -match 'VESPER_HANDOFF') { return $true }
        }
    }
    return $false
}

if ($snippet.ContainsKey('hooks')) {
    if (-not $settings.ContainsKey('hooks')) { $settings['hooks'] = @{} }

    foreach ($eventName in $snippet.hooks.Keys) {
        if (-not $settings.hooks.ContainsKey($eventName)) {
            $settings.hooks[$eventName] = @()
        }

        if (Test-VesperHookPresent -EventArray $settings.hooks[$eventName]) {
            $skipped.Add("$eventName hook already present - left untouched (remove it by hand first if you want to re-install)")
            continue
        }

        $settings.hooks[$eventName] = @($settings.hooks[$eventName]) + @($snippet.hooks[$eventName])
        $added.Add("$eventName hook")
    }
}

# --- Serialise and validate BEFORE writing ----------------------------------
# -Depth matters: the default of 2 silently mangles the nested hooks array into
# type names. This is the single easiest way to corrupt the file.
$json = $settings | ConvertTo-Json -Depth 20

try {
    $null = $json | ConvertFrom-Json
} catch {
    throw "Internal error: the merged result is not valid JSON. Nothing was written. $($_.Exception.Message)"
}

if ($added.Count -eq 0) {
    Write-Host "Nothing to do - Vesper's hooks and permissions are already present in $SettingsPath"
    foreach ($s in $skipped) { Write-Host "  - $s" }
    return
}

# --- Back up, then write ----------------------------------------------------
if ($PSCmdlet.ShouldProcess($SettingsPath, "Merge Vesper hooks and permissions")) {
    if (-not $isNew) {
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$SettingsPath.bak-$stamp"
        Copy-Item -LiteralPath $SettingsPath -Destination $backup -Force
        Write-Host "Backed up existing settings to $backup"
    }

    # UTF-8 without BOM - a BOM here is tolerated by most parsers but not all.
    [System.IO.File]::WriteAllText($SettingsPath, $json, [System.Text.UTF8Encoding]::new($false))

    Write-Host "Merged into $SettingsPath"
    foreach ($a in $added)   { Write-Host "  + $a" }
    foreach ($s in $skipped) { Write-Host "  - $s" }

    Write-Host ""
    Write-Host "NEXT - one edit this script cannot make for you:" -ForegroundColor Yellow
    Write-Host "  The PostToolUse hook contains PLACEHOLDER_PROJECT_A|PLACEHOLDER_PROJECT_B."
    Write-Host "  Replace it with a regex matching your deployable project paths, or the"
    Write-Host "  deploy guard never fires. If you have no deploy step, delete that hook."
    Write-Host ""
    Write-Host "Then verify with:  Get-Content `"$SettingsPath`" -Raw | ConvertFrom-Json"
}
