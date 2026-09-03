#!/usr/bin/env pwsh
# scan_ps.ps1 — Censor Stage-2 for PowerShell. Runs PSScriptAnalyzer (security +
# quality rules) over a path. Read-only static analysis; never executes the target.
#
# Usage: pwsh -NoProfile -File scan_ps.ps1 -Path <dir-or-file> [-Json <out.json>]
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Path,
  [string]$Json
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Path)) { Write-Error "scan_ps.ps1: path not found: $Path"; exit 2 }

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
  Write-Host "scan_ps.ps1: PSScriptAnalyzer not installed - PowerShell scan skipped."
  Write-Host "  install: Install-Module PSScriptAnalyzer -Scope CurrentUser -Force"
  Write-Host "  (Censor still runs its other stages + the LLM review; coverage note will say so.)"
  exit 3
}
Import-Module PSScriptAnalyzer -ErrorAction Stop

# The built-in rules that map to the security baseline. The analyzer runs its full
# Error/Warning set; these get a [SECURITY] tag and sort to the top.
$securityRules = @(
  'PSAvoidUsingPlainTextForPassword',
  'PSAvoidUsingConvertToSecureStringWithPlainText',
  'PSUsePSCredentialType',
  'PSAvoidUsingUsernameAndPasswordParams',
  'PSAvoidUsingInvokeExpression',
  'PSAvoidUsingComputerNameHardcoded',
  'PSAvoidUsingBrokenHashAlgorithms'
)

Write-Host "Running PSScriptAnalyzer against: $Path"
$results = Invoke-ScriptAnalyzer -Path $Path -Recurse -Severity Error, Warning -ErrorAction SilentlyContinue

if (-not $results) {
  Write-Host "  [OK] No PSScriptAnalyzer Error/Warning findings."
} else {
  $sorted = $results | Sort-Object @{ Expression = { $securityRules -contains $_.RuleName }; Descending = $true }, Severity
  foreach ($r in $sorted) {
    $tag = if ($securityRules -contains $r.RuleName) { '[SECURITY]' } else { '[quality] ' }
    $file = Split-Path $r.ScriptName -Leaf
    "{0} {1,-7} {2}:{3}  {4} - {5}" -f $tag, $r.Severity, $file, $r.Line, $r.RuleName, $r.Message
  }
}

if ($Json) {
  $out = @($results | Select-Object RuleName, Severity, ScriptName, Line, Message,
    @{ n = 'security'; e = { $securityRules -contains $_.RuleName } })
  $out | ConvertTo-Json -Depth 4 | Set-Content -Path $Json
  Write-Host "JSON written to: $Json"
}
