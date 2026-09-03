<#
.SYNOPSIS
  Detect a repo's shape, propose a Vesper config, and write it.

.DESCRIPTION
  Runs ATTENDED. This is the only part of Vesper permitted to ask questions, and
  that is deliberate: a wrong guess must be visible before the first unattended
  run, not discovered as a silently empty gate three weeks later.

  -NonInteractive writes the detected draft without prompting. It exists for
  tests and for scripted setup; it is not the normal path. Without it, setup
  refuses to run at all when no terminal is attached to answer the confirmation
  prompt - see the IsInputRedirected check below.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [switch]$NonInteractive,
    [switch]$Force,
    # Defaults to the real user-level settings file, exactly as
    # Get-VesperState.ps1's own -UserSettingsPath does, and for the identical
    # reason: a test that reads the running machine's actual allowlist asserts
    # against whatever that machine happens to carry - on the author's, 505
    # rules - which is not a test. Overridable so count-sensitive assertions
    # can pin it at a path that does not exist.
    [string]$UserSettingsPath
)

$ErrorActionPreference = 'Stop'

# --- RepoRoot must be real, and must be a git repo ---
# Setup's whole justification is making wrong guesses visible. A typo'd
# -RepoRoot is the loudest possible wrong guess - silently creating it and
# writing a config into a directory that was never the intended repo is the
# exact opposite of that, and it happened quietly before this check existed.
if (-not (Test-Path -LiteralPath $RepoRoot)) {
    throw "RepoRoot '$RepoRoot' does not exist. Refusing rather than creating it - a typo'd path deserves to fail loudly, not become a real (empty, wrong) repo."
}
$null = git -C $RepoRoot rev-parse --is-inside-work-tree 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "RepoRoot '$RepoRoot' is not a git repository (or 'git' is unavailable on PATH). Every probe this config feeds - the deploy gate, graph staleness, repo.ahead/behind - depends on git; run setup from inside the repository you mean to configure."
}

$configPath = Join-Path $RepoRoot '.vesper/config.json'
$queuePath  = Join-Path $RepoRoot '.vesper/queue.md'

if ((Test-Path -LiteralPath $configPath) -and -not $Force) {
    throw "A Vesper config already exists at '$configPath'. Re-run with -Force to replace it - your queue.md will not be touched."
}

# --- attended-mode precondition, checked BEFORE any detection or prompt runs ---
# Setup is attended BY DESIGN - it is the only part of Vesper permitted to ask
# questions, and that only means something if a human is actually there to
# answer. Read-Host against redirected stdin returns an empty string at EOF,
# which reads as an affirmative answer to whatever it was asked - so without
# this guard, any caller that runs this script through a pipe or a non-TTY
# shell (an agent, a CI job, a scheduled task) gets answers to questions no
# human ever saw, silently turning "attended" into "unattended with extra
# steps". [Console]::IsInputRedirected is the one fact that distinguishes a
# real terminal from a redirected/absent one.
#
# This check used to sit only in front of the final write-confirmation
# prompt, far below all the detection logic. Then the docs.projectMemory
# "both root and per-project files exist" fork added a SECOND Read-Host
# earlier in the script, and that prompt fired first: redirected stdin read
# as EOF, silently selected 'project', and the note it wrote said "you chose
# scope 'project'" - a fabricated claim about a decision nobody made -
# entirely on the strength of the LATER guard happening to run before
# anything got written. Checked here instead, before either prompt exists,
# so no prompt anywhere in this script can ever run against a non-interactive
# stdin, regardless of how many get added later.
if (-not $NonInteractive -and [Console]::IsInputRedirected) {
    throw "Setup is attended by design - no terminal is attached to answer a confirmation prompt (stdin is redirected), and proceeding would silently accept EOF as the answer to a question nobody was asked. Re-run with -NonInteractive to write the detected draft directly, then review .vesper/config.json yourself before trusting an unattended run against it."
}

$notes = [System.Collections.Generic.List[string]]::new()

# --- projects: look for a common prefix among top-level directories ---
$dirs = Get-ChildItem -LiteralPath $RepoRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^\.' }

$filter = $null
if ($dirs.Count -ge 2) {
    $firstWords = $dirs | ForEach-Object { ($_.Name -split ' ')[0] } | Group-Object | Sort-Object Count -Descending
    if ($firstWords -and $firstWords[0].Count -ge 2 -and $firstWords[0].Count -ge ($dirs.Count / 2)) {
        $filter = "$($firstWords[0].Name) *"
    }
}
if ($filter) {
    $notes.Add("project filter : '$filter' ($(@($dirs | Where-Object { $_.Name -like $filter }).Count) of $($dirs.Count) dirs)")
} else {
    $notes.Add("project filter : none - all top-level directories treated as projects")
}

$candidateDirs = if ($filter) { $dirs | Where-Object { $_.Name -like $filter } } else { $dirs }

# --- deploy: find the relative path used by the most projects (a single
# candidate wins outright when only one project has any deploy script at all -
# this is a "most common", not a "shared by 2+", rule) ---
$deployScript = $null
$counts = @{}
foreach ($d in $candidateDirs) {
    $found = Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)deploy' -and $_.Extension -in @('.ps1', '.sh') }
    foreach ($f in $found) {
        $rel = $f.FullName.Substring($d.FullName.Length).TrimStart('\', '/') -replace '\\', '/'
        if (-not $counts.ContainsKey($rel)) { $counts[$rel] = 0 }
        $counts[$rel]++
    }
}
if ($counts.Count -gt 0) {
    $best = $counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $deployScript = $best.Key
    $notes.Add("deploy script  : '$deployScript' (found in $($best.Value) project(s))")
} else {
    $notes.Add("deploy script  : NONE FOUND - no deploy script detected, so the deploy gate will be INERT. Set deploy.script by hand if this repo has one.")
}

# --- graph: look for a conventional cache directory, using the SAME
# "most common across projects" logic as deploy detection above. First-match-
# wins (the earlier version of this block) silently dropped every OTHER
# project's directory name from both consideration and the note - the same
# defect the deploy note already avoided by counting instead of stopping at
# the first hit. The name match itself is also loose ('graph' matches
# 'graphics', 'geography', anything) and NOTHING here can verify it is really
# a graph tool's output, so the note says so plainly rather than reporting a
# guess as a fact.
$graph = $null
$graphCounts = @{}
foreach ($d in $candidateDirs) {
    $found = Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)graph' }
    foreach ($g in $found) {
        if (-not $graphCounts.ContainsKey($g.Name)) { $graphCounts[$g.Name] = 0 }
        $graphCounts[$g.Name]++
    }
}
if ($graphCounts.Count -gt 0) {
    $bestGraph = $graphCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $graph = [ordered]@{ dir = $bestGraph.Key }
    $notes.Add("graph          : '$($bestGraph.Key)' detected (found in $($bestGraph.Value) project(s)) - name match only ('graph' anywhere in the directory name), not a verified graph-tool output. Confirm this is really the right directory before trusting graph-staleness reports.")
} else {
    $notes.Add("graph          : none detected - graph maintenance will be ABSENT (not inert)")
}

# --- docs ---
# docs.operations really is one root-relative file for every repo; detection
# for it is unchanged.
$docs = [ordered]@{ operations = $null; projectMemory = $null }
if (Test-Path -LiteralPath (Join-Path $RepoRoot 'OPERATIONS.md')) { $docs.operations = 'OPERATIONS.md' }

# docs.projectMemory now carries its own SCOPE (Get-VesperConfig.ps1 validates
# { scope: 'root'|'project', file }, or null), so detection must actually
# DECIDE between the two shapes instead of only checking the root case and
# warning about the other. A repo where every project keeps its own
# PROJECT_MEMORY.md - this very repo's own convention - used to have no single
# root-level file to declare, so this block found the per-project files, wrote
# a WARNING about them, and still wrote null: the exact thing it had just
# found, discarded. Detect both shapes and decide.
$rootMemory       = Test-Path -LiteralPath (Join-Path $RepoRoot 'PROJECT_MEMORY.md')
$perProjectMemory = @($candidateDirs | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'PROJECT_MEMORY.md') })

if ($rootMemory -and $perProjectMemory.Count -gt 0) {
    # Both exist - this is what attended mode is FOR: root vs project is a real
    # fork in what the repo means, not a guess setup should make alone.
    if ($NonInteractive) {
        # No terminal to ask. 'project' (the more specific reading) wins by
        # default, but this is the ONE branch in this whole detection pass
        # where an unattended run silently picks a convention on someone's
        # behalf - so it is reported as loudly as this script reports
        # anything: a Write-Warning as well as a note, not a note alone.
        $docs.projectMemory = [ordered]@{ scope = 'project'; file = 'PROJECT_MEMORY.md' }
        Write-Warning "Vesper: found BOTH a root-level PROJECT_MEMORY.md and $($perProjectMemory.Count) project-level PROJECT_MEMORY.md file(s). Running -NonInteractive, so nobody was asked which is this repo's real convention - PICKED scope 'project' on your behalf (the more specific of the two readings). Check docs.projectMemory in the written config; change it to { `"scope`": `"root`", `"file`": `"PROJECT_MEMORY.md`" } if the root file is actually the one that matters here."
        $notes.Add("docs.projectMemory : WARNING - both a root file and $($perProjectMemory.Count) project file(s) exist; NonInteractive picked scope 'project' UNASKED. VERIFY this guess.")
    } else {
        Write-Information "" -InformationAction Continue
        Write-Information "Both a root-level PROJECT_MEMORY.md and $($perProjectMemory.Count) project-level PROJECT_MEMORY.md file(s) exist." -InformationAction Continue
        $choice = Read-Host "Which is this repo's real convention - 'root' or 'project'? [project]"
        # Unrecognized input ABORTS rather than falling through to a default -
        # matching the write-confirmation prompt below, which does the same
        # for anything that isn't a recognizable yes/no. Silently treating
        # garbage input as 'project' and then writing "you chose scope
        # 'project'" would be a fabricated claim about a decision nobody
        # actually made, the same defect the redirected-stdin fix above
        # exists to prevent - just reachable by a typo instead of a pipe.
        if ($choice -match '^(r|root)$') {
            $scope = 'root'
        } elseif (-not $choice -or $choice -match '^(p|project)$') {
            $scope = 'project'
        } else {
            Write-Information "Aborted. Nothing written. '$choice' is neither 'root' nor 'project'." -InformationAction Continue
            return
        }
        $docs.projectMemory = [ordered]@{ scope = $scope; file = 'PROJECT_MEMORY.md' }
        $notes.Add("docs.projectMemory : both a root file and $($perProjectMemory.Count) project file(s) exist - you chose scope '$scope'")
    }
} elseif ($rootMemory) {
    $docs.projectMemory = [ordered]@{ scope = 'root'; file = 'PROJECT_MEMORY.md' }
    $notes.Add("docs.projectMemory : root-level PROJECT_MEMORY.md found - scope 'root'")
} elseif ($perProjectMemory.Count -gt 0) {
    $docs.projectMemory = [ordered]@{ scope = 'project'; file = 'PROJECT_MEMORY.md' }
    $notes.Add("docs.projectMemory : $($perProjectMemory.Count) project(s) carry their own PROJECT_MEMORY.md - scope 'project'")
} else {
    # Neither exists. This is a NORMAL outcome, not a defect: plenty of repos
    # keep no memory doc at all, or use a different tool entirely for the same
    # purpose (a ticket system, a knowledge graph). The old text here read as a
    # warning regardless of cause, because null was the only outcome this
    # block could ever produce; now that null is one of four real branches, it
    # must not read as though something is missing when nothing is.
    $notes.Add("docs.projectMemory : none found, at the root or per-project - left null. This is NORMAL if this repo keeps no memory doc at all, or uses a different tool (a ticket system, a knowledge graph) for the same purpose.")
}

$pmLabel = if ($docs.projectMemory) { "scope=$($docs.projectMemory.scope) file=$($docs.projectMemory.file)" } else { 'none' }
$notes.Add("docs           : operations=$($docs.operations ?? 'none'), projectMemory=$pmLabel")

# --- allowlist, reported for information only ---
# The probe (Get-VesperState.ps1) merges THREE settings files - user-level
# ~/.claude/settings.json, the repo's .claude/settings.json, and the
# git-ignored .claude/settings.local.json beside it - because that is what the
# harness actually reads at runtime. A note built from only the project file
# describes a fraction of the real allowlist: on a machine where the
# user-level file carries the bulk of the rules, a project-only count reads as
# "almost nothing is allowlisted" when the opposite is true. Mirror the same
# three sources here, for the same reason.
if (-not $PSBoundParameters.ContainsKey('UserSettingsPath')) {
    $UserSettingsPath = Join-Path $HOME '.claude/settings.json'
}
$userSettingsLabel = if ($UserSettingsPath -eq (Join-Path $HOME '.claude/settings.json')) {
    '~/.claude/settings.json'
} else {
    $UserSettingsPath
}
$allowCandidates = @(
    [ordered]@{ label = $userSettingsLabel;            path = $UserSettingsPath }
    [ordered]@{ label = '.claude/settings.json';       path = (Join-Path $RepoRoot '.claude/settings.json') }
    [ordered]@{ label = '.claude/settings.local.json'; path = (Join-Path $RepoRoot '.claude/settings.local.json') }
)
$allowCount = 0
$readLabels = [System.Collections.Generic.List[string]]::new()
$badLabels  = [System.Collections.Generic.List[string]]::new()
foreach ($c in $allowCandidates) {
    if (-not (Test-Path -LiteralPath $c.path)) { continue }
    try {
        # Mirror Get-VesperState.ps1's OWN failure semantics here, not just its
        # list of sources. A zero-byte or whitespace-only file, or a bare JSON
        # scalar/array, parses without throwing and would otherwise read as "we
        # read this file and it contributed 0 rules" - which is false, we did
        # not read anything usable. Same for a 'permissions' or 'allow' that
        # exists but is the wrong shape: that is a failure to determine, not a
        # determination of zero, and must land in badLabels like any other
        # unreadable file rather than silently counting as a clean pass.
        $raw = Get-Content -LiteralPath $c.path -Raw -ErrorAction Stop
        $s = $raw | ConvertFrom-Json -AsHashtable
        if ($null -eq $s -or $s -isnot [System.Collections.IDictionary]) {
            throw 'did not parse to a JSON object (empty, whitespace-only, or a bare scalar/array)'
        }
        if ($s.ContainsKey('permissions')) {
            $perms = $s['permissions']
            if ($perms -isnot [System.Collections.IDictionary]) {
                throw "'permissions' is not a JSON object"
            }
            if ($perms.ContainsKey('allow')) {
                $rules = $perms['allow']
                if ($null -eq $rules -or $rules -is [string] -or $rules -isnot [System.Collections.IEnumerable]) {
                    throw "'permissions.allow' is not a JSON array"
                }
                $allowCount += @($rules).Count
            }
        }
        $readLabels.Add($c.label)
    } catch {
        $badLabels.Add($c.label)
    }
}
if ($badLabels.Count -gt 0) {
    $notes.Add("allowlist      : UNPARSEABLE - $($badLabels -join ', ') could not be read. The effective allowlist is unknown, not empty; fix before running unattended.")
} elseif ($readLabels.Count -gt 0) {
    $notes.Add("allowlist      : $allowCount rule(s) merged from $($readLabels -join ', ')")
} else {
    $allLabels = ($allowCandidates | ForEach-Object { $_.label }) -join ', '
    $notes.Add("allowlist      : none of the three settings files exist ($allLabels) - every command form is uncovered.")
}

# Separate check, deliberately independent of the merge above: a real user
# machine's ~/.claude/settings.json exists almost always (505 rules on the
# author's), so folding this warning into the "none of the three exist"
# branch made it UNREACHABLE in practice - a repo with no .claude/ directory
# at all still printed only the healthy-looking merged count and nothing else,
# in exactly the repo that most needs telling. Merge-VesperHooks.ps1 writes
# the return-leg hook into the repo's own .claude/settings.json by default, so
# that file's absence is checked on its own, regardless of what the merge found.
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.claude/settings.json'))) {
    $notes.Add("allowlist      : this repo has no '.claude/settings.json' - the return-leg hook is NOT installed here (Merge-VesperHooks.ps1 writes it there by default). Run it before trusting an unattended return.")
}

# --- install: where THIS instance of Vesper is running from ---
# Needed below only to locate the bundled templates/queue.md - nothing else
# reads it. It used to also be RECORDED into the config, as install.skillDir,
# so the running agent had a second way to find SKILL.md's state-probe script
# when the directory this SKILL.md was read from was not visible. That field
# is retired: SKILL.md's probe line now names ${CLAUDE_SKILL_DIR}, a runtime
# variable the harness itself resolves to the directory containing SKILL.md -
# identically for a copied skill and a marketplace plugin install - so there
# is no installation-specific path left for a config field to carry, and
# Get-VesperConfig.ps1 refuses a config that still has one (see its retired-
# keys section).
$skillDir = (Resolve-Path -LiteralPath (Split-Path $PSScriptRoot -Parent)).Path

$config = [ordered]@{
    projects    = [ordered]@{ root = '.'; filter = $filter }
    deploy      = [ordered]@{ script = $deployScript; excludeRx = 'parse' }
    graph       = $graph
    maintenance = [ordered]@{ queue = '.vesper/queue.md' }
    docs        = $docs
}

foreach ($n in $notes) { Write-Information "  $n" -InformationAction Continue }

if (-not $NonInteractive) {
    # The redirected-stdin guard now lives at the TOP of this script, before
    # any detection or prompt runs (see the attended-mode precondition
    # above) - not here. It used to sit only in front of this prompt, which
    # let an earlier prompt (docs.projectMemory's "both" fork) run first
    # against redirected stdin and act on a fabricated EOF answer before this
    # guard ever got a chance to fire. Reaching this line therefore already
    # means a real terminal is attached.
    Write-Information "" -InformationAction Continue
    $answer = Read-Host "Write this config to .vesper/config.json? [Y/n]"
    if ($answer -and $answer -notmatch '^(y|yes)$') {
        Write-Information "Aborted. Nothing written." -InformationAction Continue
        return
    }
}

New-Item -ItemType Directory -Path (Join-Path $RepoRoot '.vesper') -Force | Out-Null
($config | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $configPath -Encoding utf8

if (-not (Test-Path -LiteralPath $queuePath)) {
    # templates/ ships INSIDE the skill root, so this one path is correct in
    # every layout this script ever runs from:
    #
    #   dev tree:  .../next/skill/vesper/scripts/Invoke-VesperSetup.ps1
    #   installed: ~/.claude/skills/vesper/scripts/Invoke-VesperSetup.ps1
    #
    # The earlier version also tried a SIBLING location two levels above the
    # skill root, for a dev tree that kept templates/ outside skill/vesper/.
    # That branch could only ever fire in the dev tree, and it had to be
    # fenced by a directory-NAME check ("skill" singular vs "skills" plural),
    # because the same hop count from a real install lands on ~/.claude/ - the
    # root of the user's entire shared Claude config directory. The fence held;
    # what did not was the premise. Install-Vesper.ps1 copies skill/vesper/*
    # and nothing else, so templates/ reached no install at all, the
    # inside-the-skill branch could never hit, the fenced branch could never
    # fire, and every real install silently wrote the stub. Shipping templates/
    # inside the skill deletes the fork, the fence and the hazard together:
    # what the installer copies is what setup reads.
    $template = Join-Path $skillDir 'templates/queue.md'

    if (Test-Path -LiteralPath $template) {
        Copy-Item -LiteralPath $template -Destination $queuePath
    } else {
        # LOUD, not silent. The previous fallback printed "Wrote
        # .vesper/queue.md" and nothing else, so a packaging fault that kept
        # templates/ out of the install was indistinguishable from success -
        # in the one component whose entire justification is loudness. The
        # stub carries none of the starter items' discipline (the allowlist
        # check before running anything, the working-directory precondition
        # that keeps memory hygiene from prompting mid-evening), so a user who
        # is not told has a queue that looks written and is not.
        Set-Content -LiteralPath $queuePath -Value "# Maintenance queue`n`nAdd items here. Rules live in the skill's maintenance-rules.md.`n" -Encoding utf8
        Write-Information "  queue          : WARNING - the starter template was NOT found at '$template', so '$queuePath' is a three-line STUB, not the starter queue. That means this skill was installed without its templates/ directory. The stub carries none of the starter items - no test-suite check, no documentation-drift item, and none of the permission or working-directory discipline that keeps an unattended run from halting on a prompt. Reinstall the skill, or write the queue yourself before trusting an unattended run." -InformationAction Continue
        Write-Warning "Vesper: starter queue template not found at '$template' - wrote a three-line STUB instead, not the starter queue. Reinstall the skill (its templates/ directory is missing) or write .vesper/queue.md yourself."
    }
}

Write-Information "" -InformationAction Continue
Write-Information "Wrote $configPath" -InformationAction Continue
Write-Information "Wrote $queuePath" -InformationAction Continue

# --- the return leg -----------------------------------------------------
# SKILL.md states that Vesper's return leg is carried ENTIRELY by a SessionStart
# hook in the repo's .claude/settings.json, not by the skill - because a skill
# cannot fix a session it never loads in, and the morning you most need the
# reminder is a morning you opened Claude for something else.
#
# Setup used to only NAME Merge-VesperHooks.ps1, which lived in the kit and was
# therefore absent from every installed skill. A stranger installed Vesper, ran
# setup, and got a Vesper with a working departure leg, NO morning leg, and an
# instruction to run a script they did not have. The script now ships beside
# this one, so the instruction resolves - and setup OFFERS to run it, because
# setup is the one attended part of Vesper and an offer is legitimate here.
$merge = Join-Path $PSScriptRoot 'Merge-VesperHooks.ps1'
$repoSettings = Join-Path $RepoRoot '.claude/settings.json'

$hookPresent = $false
if (Test-Path -LiteralPath $repoSettings) {
    try {
        $existing = Get-Content -LiteralPath $repoSettings -Raw
        # Same idempotency key Merge-VesperHooks.ps1 uses: the handoff filename
        # appears in both hooks and in nothing else.
        $hookPresent = $existing -match 'VESPER_HANDOFF'
    } catch { $hookPresent = $false }
}

Write-Information "" -InformationAction Continue
if ($hookPresent) {
    Write-Information "Return leg : already installed - '$repoSettings' carries a Vesper hook." -InformationAction Continue
}
elseif (-not (Test-Path -LiteralPath $merge)) {
    # Cannot happen from a complete install; says so plainly if it does.
    Write-Warning "Vesper: the return leg is NOT installed and Merge-VesperHooks.ps1 is missing from '$PSScriptRoot'. Vesper's departure leg will work and its return leg will not exist. Reinstall the skill."
}
elseif ($NonInteractive) {
    # No prompting without a human. Report LOUDLY instead - this is the item
    # whose absence costs the whole return leg, and silence here is what left
    # a deploy gate open for three days once already.
    Write-Warning "Vesper: the return leg is NOT installed in this repo. Vesper's departure leg will work and every morning will be silent, while SKILL.md describes the hook as though it were there."
    Write-Information "Return leg : NOT INSTALLED. Run this, from inside the repo, before trusting an unattended return:" -InformationAction Continue
    Write-Information "  pwsh `"$merge`" -SettingsPath `"$repoSettings`"" -InformationAction Continue
}
else {
    Write-Information "Vesper's return leg lives in a SessionStart hook in '$repoSettings', not in the skill." -InformationAction Continue
    Write-Information "Without it the departure leg works and every morning is silent." -InformationAction Continue
    $hookAnswer = Read-Host "Install the hooks into that file now? [Y/n]"
    if ($hookAnswer -and $hookAnswer -notmatch '^(y|yes)$') {
        Write-Information "Skipped. Run this yourself before trusting an unattended return:" -InformationAction Continue
        Write-Information "  pwsh `"$merge`" -SettingsPath `"$repoSettings`"" -InformationAction Continue
    } else {
        # Merge-VesperHooks.ps1 backs up first, validates the merged JSON before
        # writing, and leaves an existing Vesper hook alone. A failure here must
        # not lose the config setup just wrote, so it is reported, not rethrown.
        try {
            & $merge -SettingsPath $repoSettings
        } catch {
            Write-Warning "Vesper: the hook merge failed - $($_.Exception.Message). The config and queue were written; the return leg is NOT installed. Run 'pwsh `"$merge`" -SettingsPath `"$repoSettings`"' by hand."
        }
    }
}

return $configPath
