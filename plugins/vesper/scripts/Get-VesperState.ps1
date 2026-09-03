<#
.SYNOPSIS
  Read-only state probe for Vesper. Emits one JSON object on stdout.

  NEVER writes, NEVER mutates git state, ALWAYS exits 0. Probe failures are
  reported in errors[] so a single broken probe cannot take down a departure
  sequence.
.EXAMPLE
  pwsh ~/.claude/skills/vesper/scripts/Get-VesperState.ps1 -RepoRoot "<repo root>" -ConfigPath "<repo root>/.vesper/config.json"
  pwsh ~/.claude/skills/vesper/scripts/Get-VesperState.ps1 -RepoRoot "<repo root>" -ConfigPath "<repo root>/.vesper/config.json" -Baseline 4d843e9

  Inside SKILL.md itself the path is the ${CLAUDE_SKILL_DIR} runtime variable,
  not a hand-typed location - see that file's "State probe" section.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$Baseline,
    [string]$MemoryPath,
    [int]$GraphStaleCommits = 3,
    [string]$ConfigPath,
    # Defaults to the real user-level settings file, exactly as -MemoryPath
    # defaults to the real auto-memory folder. Overridable for the same reason:
    # a test that reads the running machine's actual allowlist asserts against
    # whatever that machine happens to carry, which is not a test.
    [string]$UserSettingsPath
)

$ErrorActionPreference = 'Continue'

$errors = [System.Collections.Generic.List[object]]::new()

function Add-ProbeError {
    param([string]$Probe, [string]$Message)
    $errors.Add([ordered]@{ probe = $Probe; message = $Message })
}

# Trim FIRST, then test. Testing before trimming let '-RepoRoot " "' through as
# a "supplied" root, and the later .Trim() on an all-whitespace string yielded
# '' - which the git calls then failed against, emitting a non-JSON error
# record ahead of the JSON on stdout. This script's contract is one JSON object.
#
# Resolved HERE, before config loading below, so the fully-resolved -RepoRoot
# can be passed straight through to Get-VesperConfig.ps1 instead of being
# re-derived from -ConfigPath. Deriving it from the path was itself a bug: it
# silently opened '<derived-root>/.vesper/config.json' regardless of what file
# the caller actually named, and broke outright on a relative -ConfigPath.
if ($null -ne $RepoRoot) { $RepoRoot = "$RepoRoot".Trim() }
if (-not $RepoRoot) {
    $RepoRoot = (git rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if ($null -ne $RepoRoot) { $RepoRoot = "$RepoRoot".Trim() }
    if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }
}

# Resolve to an ABSOLUTE path. Every caller-facing instruction in SKILL.md says
# to pass "<repo root>", and an agent standing in the repo passes `.` - which is
# a correct repo root and a broken memory slug: Get-MemorySlug turns '.' into
# '.', and memoryPath becomes '~/.claude/projects/./memory', a directory that
# does not exist. The probe then reports "auto-memory path not found" and memory
# hygiene is inert for the evening, with nothing to distinguish that from a
# machine that genuinely has no memory folder. Resolving here fixes it once, for
# every caller, instead of asking the prose to warn about it - a caveat only
# helps a reader who happens to read it.
#
# GetFullPath, not Resolve-Path: this probe must never throw, and Resolve-Path
# raises on a path that does not exist. GetFullPath normalizes without touching
# the filesystem, so a nonexistent -RepoRoot still reaches Get-RepoBlock and is
# reported there as "not a git repository", which is the honest error.
if ($RepoRoot) {
    try { $RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot) } catch { }
}

# Config is OPTIONAL to the probe. A probe that refused to run without one could
# not be used to diagnose a repo that has not been set up yet - and the probe's
# contract is to always exit 0. Missing config falls back to the historical
# defaults and says so.
#
# The schema authority is Get-VesperConfig.ps1 (Task 2) - it validates empty
# config, a non-object top level, missing/null required sections, an empty
# deploy.script, a malformed graph section, and declared-but-missing docs
# paths. Re-implementing a second, lenient loader here would make THIS probe
# the one place those checks don't apply. It throws by design (a wrong config
# means the repo cannot be trusted to describe itself); the probe never
# throws, so it is invoked and wrapped instead. A config that fails to load
# is all-or-nothing: the probe does not half-apply a rejected config, it
# falls all the way back to built-in defaults and says so loudly.
#
# $configRequested tracks INTENT (a path was supplied), not OUTCOME (a config
# object materialized). Gating the loud discovery errors below on the outcome
# instead of the intent would silently disable them for exactly the user who
# most needs them: one whose -ConfigPath is wrong (typo, stale .vesper/,
# wrong cwd) or unreadable - they would get built-in defaults AND lose the
# check that was supposed to tell them so.
$script:vesperConfig = $null
$configRequested = [bool]$ConfigPath
if ($configRequested) {
    try {
        $script:vesperConfig = & (Join-Path $PSScriptRoot 'Get-VesperConfig.ps1') `
            -RepoRoot $RepoRoot -ConfigPath $ConfigPath
    } catch {
        Add-ProbeError -Probe 'config' -Message "config at '$ConfigPath' is unusable - every config-driven probe is running on built-in defaults: $($_.Exception.Message)"
    }
}

function Get-ConfigValue {
    param([string]$Section, [string]$Key, $Default)
    if ($null -eq $script:vesperConfig) { return $Default }
    if (-not $script:vesperConfig.ContainsKey($Section)) { return $Default }
    $s = $script:vesperConfig[$Section]
    if ($null -eq $s) { return $null }
    if (-not $s.ContainsKey($Key)) { return $Default }
    return $s[$Key]
}

# projects.filter is ONE field, resolved ONCE and shared by both deploy
# discovery and graph discovery. Before this, each probe called
# Get-ConfigValue with its own default (unfiltered vs 'Project *') - correct
# for the no-config fallback (each site's own historical convention), but
# once a config exists it meant a bare {"projects":{"root":"."}} silently
# gave unfiltered deploy discovery and 'Project *' graph discovery: the two
# folder conventions this task exists to unify, diverging again one layer
# down. Get-ConfigValue's own null-config short-circuit already makes this
# resolve to $null (unfiltered) when there is no config, matching
# Get-WebProjectBlock's historical default; Get-GraphBlock substitutes its
# own historical 'Project *' default explicitly, only on the no-config path.
$script:projectFilter = Get-ConfigValue -Section 'projects' -Key 'filter' -Default $null

# projects.root selects WHICH DIRECTORY deploy discovery and graph discovery
# scan, shared by both for the same reason projectFilter above is shared: a
# probe that read it for one and not the other would have the two
# conventions this task exists to unify diverging again one layer down.
#
# Before this, nothing ever joined projects.root onto $RepoRoot - both
# Get-WebProjectBlock and Get-GraphBlock were always called with -Root
# $RepoRoot regardless of config, so a repo whose projects actually live
# under 'src' (projects.root: "src") got webProjects: 0 and graphs: 0 with an
# error naming the REPO ROOT rather than 'src'. That is "present, non-null,
# and inert" - present because Get-VesperConfig.ps1 validates it (and even
# resolves it to check docs.projectMemory scope 'project'), non-null because
# setup always writes a value, inert because the probe never read it back.
#
# Default is $RepoRoot itself, matching Get-VesperConfig.ps1's own '.'
# convention and the historical no-config fallback (every caller before this
# scanned the repo root). Get-VesperConfig.ps1 has already confirmed the
# joined path exists when a config loaded - projects.root is a required,
# non-empty, existence-checked field there - so no second existence check is
# needed here; this probe just has to honour what Task 2 already validated
# instead of silently discarding it.
$script:projectsRoot = $RepoRoot
$cfgProjectsRoot = Get-ConfigValue -Section 'projects' -Key 'root' -Default $null
if (-not [string]::IsNullOrWhiteSpace($cfgProjectsRoot)) {
    $joined = Join-Path $RepoRoot $cfgProjectsRoot
    try { $script:projectsRoot = [System.IO.Path]::GetFullPath($joined) } catch { $script:projectsRoot = $joined }
}

function Get-MemorySlug {
    # Claude Code names its per-project memory folder after the repo path. The
    # transformation differs by platform: Windows has a drive letter and a colon
    # to strip, POSIX has neither. This is the ONLY OS-shaped code in the probe -
    # everything else is platform-neutral PowerShell 7.
    #
    # -ForcePosix exists for tests: POSIX behaviour cannot otherwise be exercised
    # from Windows, and an untestable branch is one that rots.
    param(
        [string]$Path,
        [switch]$ForcePosix
    )
    if (-not $Path) { return '' }

    $isPosix = $ForcePosix -or (-not $IsWindows)

    if ($isPosix) {
        $p = $Path.TrimEnd('/')
        return ($p -replace '/', '-')
    }

    $p = ($Path -replace '/', '\').TrimEnd('\')
    if ($p -match '^[A-Za-z]:') { $p = $p.Substring(0, 1).ToLower() + $p.Substring(1) }
    return ($p -replace '[:\\]', '-')
}

function Get-RepoBlock {
    param([string]$Root)

    $branch = (git -C $Root rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $branch) {
        Add-ProbeError -Probe 'repo' -Message "not a git repository: $Root"
        return $null
    }

    $head = (git -C $Root rev-parse HEAD 2>$null).Trim()

    # Porcelain rename/copy entries read "R  old -> new". Substring(3) alone
    # yields the literal string "old -> new", which is not a path - and the
    # protocol hands these straight to `git add -- "<path>"` and to the
    # "pre-existing uncommitted" list. Split them into both real paths.
    $uncommitted = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (git -C $Root status --porcelain 2>$null | Where-Object { $_ })) {
        $rest = $line.Substring(3)
        foreach ($part in ($rest -split ' -> ')) {
            $p = $part.Trim().Trim('"')
            if ($p) { $uncommitted.Add($p) }
        }
    }
    $uncommitted = @($uncommitted | Select-Object -Unique)

    # null, NOT 0, when the counts cannot be computed. "0 commits behind" and
    # "no upstream to compare against" are different facts, and the protocol
    # consumes behind as if it were measured.
    $ahead = $null; $behind = $null
    $counts = git -C $Root rev-list --left-right --count '@{upstream}...HEAD' 2>$null
    if ($LASTEXITCODE -eq 0 -and $counts) {
        $parts  = $counts -split '\s+'
        $behind = [int]$parts[0]
        $ahead  = [int]$parts[1]
    } else {
        Add-ProbeError -Probe 'repo' -Message "could not compute ahead/behind for branch '$($branch.Trim())' - no upstream is configured or '@{upstream}' does not resolve; ahead/behind are null, NOT zero. Do not read them as in-sync with origin."
    }

    return [ordered]@{
        branch      = $branch.Trim()
        head        = $head
        ahead       = $ahead
        behind      = $behind
        uncommitted = $uncommitted
    }
}

function Test-Baseline {
    param([string]$Root, [string]$Baseline)

    if (-not $Baseline) { return $false }
    git -C $Root cat-file -e "$Baseline^{commit}" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Dot-prefixed directories are never projects. With projects.filter null -
# which is exactly what setup writes for a repo with no common prefix - an
# unfiltered Get-ChildItem returns '.vesper', '.claude', '.github' and every
# other tooling directory, so Vesper's OWN config directory got reported as a
# project of the repo it was configuring. Filtering here rather than in the
# caller keeps deploy discovery and graph discovery agreeing, which is the
# whole point of resolving projects.filter once.
function Get-ProjectDirs {
    param([string]$Root, [string]$Filter)
    $dirs = if ($Filter) {
        Get-ChildItem -LiteralPath $Root -Directory -Filter $Filter -ErrorAction SilentlyContinue
    } else {
        Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue
    }
    return @($dirs | Where-Object { $_.Name -notmatch '^\.' })
}

function Get-WebProjectBlock {
    param([string]$Root, [string]$Baseline, [bool]$BaselineValid)

    $results = [System.Collections.Generic.List[object]]::new()
    if (-not $Baseline) { return $results }

    $filter       = $script:projectFilter
    $deployScript = Get-ConfigValue -Section 'deploy' -Key 'script' -Default 'scripts/deploy_changed.ps1'

    # -LiteralPath throughout: a project directory whose name contains [ or ]
    # is a valid wildcard expression, so a wildcard-aware Test-Path silently
    # finds nothing and drops that whole project out of the deploy gate.
    $projectDirs = Get-ProjectDirs -Root $Root -Filter $filter

    # These two loud-error checks are new, config-driven diagnostics: they fire
    # whenever a config was REQUESTED (-ConfigPath supplied), not only when one
    # successfully loaded. Gating on the loaded OBJECT instead of the request
    # would silently disable both checks for a config that was declared but
    # unusable (missing file, empty file, bad JSON) - exactly the user who most
    # needs to be told their config isn't taking effect. The true no-config
    # fallback (-ConfigPath never supplied at all) must still reproduce the old
    # silent behaviour exactly, or an unmigrated repo - which has no way to
    # satisfy either check - would start failing on a probe that used to run
    # clean.
    if ($configRequested -and (-not $projectDirs -or @($projectDirs).Count -eq 0)) {
        Add-ProbeError -Probe 'projects' -Message "no project directories matched under '$Root'$(if ($filter) { " with filter '$filter'" }). Every project-scoped probe (deploy gate, graph staleness) has nothing to act on."
    }

    # deploy.script null/empty means THIS REPO HAS NO DEPLOY STEP. Discovery
    # must stop here, unconditionally, before a single path is joined.
    #
    # Running on it: Join-Path against a null child returns the DIRECTORY, and
    # Test-Path on a directory is true - so every project directory registered
    # as its own deploy script. An empty script path also splits into exactly
    # ONE segment, so the walk-up below climbed one level too far and named
    # every entry after the repo root. The result was a webProjects[] of
    # fabricated entries whose deployScript is a directory and whose `command`
    # departure-protocol.md instructs the agent to copy VERBATIM into the
    # handoff - with deployPending false, so the INERT check below never fired
    # either.
    #
    # This is not a hypothetical config. null is what Invoke-VesperSetup.ps1
    # itself writes when it detects no deploy script, and what
    # Get-VesperConfig.ps1's own refusal message instructs the user to set.
    if ([string]::IsNullOrWhiteSpace($deployScript)) {
        Add-ProbeError -Probe 'webProjects' -Message "deploy.script is null or empty, so this repo declares no deploy step. The deploy gate is INERT, not passing: it cannot report a pending deploy for any project, and no webProjects entry exists to carry a deploy command. Set deploy.script in the Vesper config if this repo does have one, or accept that pushes are ungated here."
        return $results
    }

    $deployScripts = $projectDirs |
        ForEach-Object { Join-Path $_.FullName $deployScript } |
        Where-Object { Test-Path -LiteralPath $_ }

    if ($configRequested -and (-not $deployScripts -or @($deployScripts).Count -eq 0)) {
        Add-ProbeError -Probe 'webProjects' -Message "no deploy script found at '$deployScript' under any project directory. The deploy gate is INERT, not passing: it cannot report a pending deploy for any project. Declare the correct deploy.script in .vesper/config.json, or accept that pushes are ungated in this repo."
    }

    foreach ($script in $deployScripts) {
        # $deployScript's own segment count tells us how many path levels to
        # walk up from the resolved script to reach the project directory - one
        # Split-Path -Parent per segment (a 2-segment 'scripts/x.ps1' needs 2
        # calls, not 3: the off-by-one of looping while $i -le $depth walks one
        # level too far and reports the repo root's name instead of the project's).
        $depth = ($deployScript -split '[\\/]').Count
        $projectDir = $script
        for ($i = 0; $i -lt $depth; $i++) { $projectDir = Split-Path $projectDir -Parent }
        $projectName = Split-Path $projectDir -Leaf
        $relScript   = "$projectName/$deployScript"

        # Fail CLOSED on an unresolvable baseline. A silently-empty diff would
        # make the deploy gate vanish; a false "nothing to deploy" is the one
        # answer this probe must never give.
        if (-not $BaselineValid) {
            $results.Add([ordered]@{
                name          = $projectName
                deployScript  = $relScript
                excludeSource = 'unknown'
                pendingFiles  = @()
                orphanFiles   = @()
                deployPending = $true
                command       = "pwsh `"$relScript`""
                note          = 'baseline unresolvable - gate failed closed; confirm the correct -Ref before deploying (the command above falls back to the script default HEAD~1)'
            })
            continue
        }

        # deploy.excludeRx is CONSUMED here, not merely written. Setup emitted
        # it and nothing read it, so a user who set a literal pattern - which
        # the design spec explicitly permits - got it silently ignored and
        # watched every excluded file ride the deploy gate anyway. That is the
        # "present, non-null, and inert" state the schema exists to forbid.
        #
        #   'parse' (the default)  read the pattern out of each deploy script
        #                          at runtime, so three scripts with three
        #                          different patterns each stay correct
        #   any other string       use it AS the pattern, for a repo whose
        #                          deploy scripts carry no such assignment
        #   null                   no exclusions at all - every changed file
        #                          counts toward the gate
        #
        # Get-VesperConfig.ps1 has already compiled a literal pattern, so an
        # unusable regex cannot reach this loop: this probe must never throw.
        $excludeRx     = $null
        $excludeSource = 'fallback'
        $cfgExclude    = Get-ConfigValue -Section 'deploy' -Key 'excludeRx' -Default 'parse'

        if ([string]::IsNullOrWhiteSpace($cfgExclude)) {
            # Declared null: the user has said this repo excludes nothing. That
            # is a decision, not a failure, so it gets its own source label
            # instead of the 'fallback' one that fires a loud error below.
            $excludeSource = 'none'
        }
        elseif ($cfgExclude -ne 'parse') {
            $excludeRx     = $cfgExclude
            $excludeSource = 'config'
        }
        else {
            try {
                $text = Get-Content -LiteralPath $script -Raw -ErrorAction Stop
                if ($text -match "(?m)^\s*\`$excludeRx\s*=\s*'([^']+)'") {
                    $excludeRx     = $Matches[1]
                    $excludeSource = 'parsed'
                }
            } catch {
                Add-ProbeError -Probe 'webProjects' -Message "unreadable deploy script: $script"
            }
            if ($excludeSource -eq 'fallback') {
                Add-ProbeError -Probe 'webProjects' -Message "could not parse `$excludeRx from $script - treating all changes as deployable"
            }
        }

        $prefix  = "$projectName/"
        $changed = @(
            git -C $Root diff --name-only --diff-filter=ACMR $Baseline HEAD -- $prefix 2>$null |
                Where-Object { $_ }
        )

        # Deletes and renames leave the OLD path live on the server. That is a
        # separate signal needing manual cleanup - deliberately NOT folded into
        # deployPending, because deploy_changed.ps1 cannot clear it.
        $orphans = [System.Collections.Generic.List[string]]::new()
        $status  = @(
            git -C $Root diff --name-status --diff-filter=DR $Baseline HEAD -- $prefix 2>$null |
                Where-Object { $_ }
        )
        foreach ($line in $status) {
            $parts = $line -split "`t"
            if ($parts.Count -lt 2) { continue }
            # D<TAB>path  ->  path is gone
            # R###<TAB>old<TAB>new  ->  old is gone
            $orphans.Add($parts[1].Trim())
        }

        if ($excludeRx) {
            $changed     = @($changed | Where-Object { $_ -notmatch $excludeRx })
            $orphanFiles = @($orphans | Where-Object { $_ -notmatch $excludeRx })
        } else {
            $orphanFiles = @($orphans)
        }

        $results.Add([ordered]@{
            name          = $projectName
            deployScript  = $relScript
            excludeSource = $excludeSource
            pendingFiles  = $changed
            orphanFiles   = $orphanFiles
            deployPending = ($changed.Count -gt 0)
            command       = "pwsh `"$relScript`" -Ref $Baseline"
        })
    }

    return $results
}

function Get-GraphBlock {
    param([string]$Root, [int]$StaleCommits)

    $results = [System.Collections.Generic.List[object]]::new()

    # Shared with Get-WebProjectBlock once a config exists (Fix 3); only the
    # true no-config path keeps this function's own historical 'Project *'
    # default, because $script:projectFilter itself resolves to $null
    # (unfiltered) when there is no config to read.
    $filter   = if ($null -ne $script:vesperConfig) { $script:projectFilter } else { 'Project *' }
    $graphCfg = if ($null -eq $script:vesperConfig) { @{ dir = 'graphify-out' } } else { $script:vesperConfig['graph'] }

    # graph: null means the item is ABSENT. Return nothing rather than an empty
    # shell that reads as "no graphs are stale".
    if ($null -eq $graphCfg) { return $results }

    $graphDirName = if ($graphCfg.ContainsKey('dir')) { $graphCfg['dir'] } else { 'graphify-out' }
    $projects = Get-ProjectDirs -Root $Root -Filter $filter

    # The graph directory to skip is whatever graph.dir NAMES, not a literal.
    # This regex previously hard-coded 'graphify-out' - one tool's output
    # folder - so a repo declaring any other graph.dir had its graph
    # directory counted as source, which makes newestSourceDate track the
    # graph's own rebuild rather than the project's work. It also skipped
    # 'Outdated', an archive-folder convention private to the repo this was
    # written in, with no meaning elsewhere and no business in a shipped tool.
    $skipRx = "[\\/](" + [regex]::Escape($graphDirName) + "|\.git)[\\/]"
    foreach ($p in $projects) {
        $graphDir = Join-Path $p.FullName $graphDirName
        $hasGraph = Test-Path -LiteralPath $graphDir

        $graphDate = $null
        if ($hasGraph) {
            $graphDate = (Get-ChildItem -LiteralPath $graphDir -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        }

        $newestSource = (Get-ChildItem -LiteralPath $p.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch $skipRx } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime

        # "Any source mtime newer than any graph mtime" is true forever after a
        # single commit - it flagged every graph-bearing project permanently.
        # Count COMMITS touching the project since the graph was built instead,
        # so stale means substantive change.
        $commitsSince = 0
        if ($hasGraph -and $graphDate) {
            $since = $graphDate.ToString('o')
            $count = git -C $Root rev-list --count "--since=$since" HEAD -- `
                "$($p.Name)/" ":(exclude)$($p.Name)/$graphDirName/" 2>$null
            if ($LASTEXITCODE -eq 0 -and $null -ne $count) {
                $commitsSince = [int]("$count".Trim())
            } else {
                Add-ProbeError -Probe 'graphs' -Message "could not count commits since the graph date for $($p.Name)"
            }
        }

        $stale = ($hasGraph -and $commitsSince -ge $StaleCommits)

        $results.Add([ordered]@{
            project           = $p.Name
            hasGraph          = $hasGraph
            graphDate         = if ($graphDate) { $graphDate.ToString('s') } else { $null }
            newestSourceDate  = if ($newestSource) { $newestSource.ToString('s') } else { $null }
            commitsSinceGraph = $commitsSince
            staleThreshold    = $StaleCommits
            stale             = $stale
        })
    }

    return $results
}

function Get-MemoryBlock {
    param([string]$Path)

    $results = [System.Collections.Generic.List[object]]::new()
    if (-not $Path) { return $results }
    if (-not (Test-Path -LiteralPath $Path)) {
        Add-ProbeError -Probe 'memory' -Message "auto-memory path not found: $Path - memory hygiene cannot run this session"
        return $results
    }

    $markers = @('pending', 'awaiting', 'TODO', 'not yet verified', 'unverified')

    foreach ($file in Get-ChildItem -LiteralPath $Path -Filter '*.md' -File -ErrorAction SilentlyContinue) {
        if ($file.Name -eq 'MEMORY.md') { continue }
        $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }

        $hits = @($markers | Where-Object { $text -match [regex]::Escape($_) })
        if ($hits.Count -gt 0) {
            $results.Add([ordered]@{
                file         = $file.Name
                staleMarkers = $hits
                ageDays      = [int]((Get-Date) - $file.LastWriteTime).TotalDays
            })
        }
    }

    return $results
}

function Get-OperationsBlock {
    param([string]$Root)

    # WHICH file this is comes from config docs.operations. Hardcoding
    # 'OPERATIONS.md' here made the protocol prose advertise a key the probe
    # ignored: a repo declaring docs.operations = 'ops/RUNBOOK.md' passed
    # Get-VesperConfig.ps1's existence check, then got operations: null and
    # never fired the overdue signal - a configured item silently inert, which
    # is the exact failure mode this refactor exists to remove.
    #
    # The default keeps the no-config path byte-identical: Get-ConfigValue
    # short-circuits to $Default when there is no config at all.
    $rel = Get-ConfigValue -Section 'docs' -Key 'operations' -Default 'OPERATIONS.md'

    # null/empty means ABSENT, never 'present but inert' - docs.operations: null
    # deletes this signal rather than pointing it at a fallback file the user
    # never named.
    if ([string]::IsNullOrWhiteSpace($rel)) { return $null }

    # A missing operations doc is reported as null, NOT as a probe error. Task 1's
    # temp fixtures have no OPERATIONS.md, and its "reports no errors" assertion
    # must keep passing once this block lands.
    $path = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $age  = [int]((Get-Date) - $item.LastWriteTime).TotalDays

        return [ordered]@{
            path         = $rel
            lastModified = $item.LastWriteTime.ToString('s')
            ageDays      = $age
            overdue      = ($age -gt 120)
        }
    } catch {
        Add-ProbeError -Probe 'operations' -Message "could not read the operations doc at $path - $($_.Exception.Message)"
        return $null
    }
}

# $RepoRoot was already trimmed and resolved near the top of the script,
# before config loading needed it.
if (-not $MemoryPath) {
    $slug = Get-MemorySlug -Path $RepoRoot
    $MemoryPath = Join-Path $HOME ".claude/projects/$slug/memory"
}

if (-not $PSBoundParameters.ContainsKey('UserSettingsPath')) {
    $UserSettingsPath = Join-Path $HOME '.claude/settings.json'
}

$repo = Get-RepoBlock -Root $RepoRoot

if (-not $Baseline -and $repo) { $Baseline = $repo.head }

$baselineValid = Test-Baseline -Root $RepoRoot -Baseline $Baseline
if ($Baseline -and -not $baselineValid) {
    Add-ProbeError -Probe 'baseline' -Message "baseline '$Baseline' does not resolve to a commit - deploy gate FAILED CLOSED (deployPending forced true for every web project)"
}
elseif (-not $Baseline) {
    # No baseline at all means no repo block, which means webProjects[] is EMPTY
    # rather than fail-closed. "baselineValid: false over an empty array" reads
    # as "every project pending" and is vacuously true - the gate has vanished,
    # not failed closed. Say so loudly instead of returning a quiet empty state.
    Add-ProbeError -Probe 'baseline' -Message "no baseline could be determined - repo root '$RepoRoot' is unusable (not a git repository, or HEAD does not resolve). webProjects[] is EMPTY, not clear: the deploy gate could not be evaluated at all. Re-run with a correct -RepoRoot before trusting any deploy claim."
}

function Get-PermissionsBlock {
    param([string]$Root, [string]$UserSettingsPath)

    # The protocol needs to know which command forms are allowlisted so it can
    # avoid a prompt during an unattended run. Reporting the live list turns a
    # hard-coded conclusion into a runtime test - the same defect that made
    # maintenance item 1 declare itself "inert" and stay that way after the
    # world changed.
    #
    # ALL THREE settings files are read and MERGED, because that is what the
    # harness actually does. Reading only the project file was not a smaller
    # version of the truth, it was a different claim: measured on the author's
    # machine the user-level file carried 505 allow rules against the project
    # file's 8, so a project-only probe saw 1.6% of the effective allowlist and
    # reported 'absent' - "nothing is allowlisted" - for a machine where almost
    # everything was. Every consumer of this block reasons about whether a
    # command will prompt; answering that from one third of the input produces
    # confident wrong answers in the expensive direction.
    #
    # `status` carries the three-way truth `source` alone cannot:
    #   'ok'      - at least one file was read and parsed; allow[] is real as
    #               far as the files named in source[] go.
    #   'unknown' - a file that EXISTS could not be read or parsed, so the
    #               merged allowlist is incomplete by failure. This outranks
    #               'ok': a partial list presented as complete is the one
    #               answer that gets a command run when it should not have been.
    #   'absent'  - none of the three files exist at all. Only now does an
    #               empty allow[] mean "nothing is allowlisted" rather than
    #               "we did not manage to look".
    # `source` is an ARRAY of the files actually read - real paths, never a
    # sentinel word, so a consumer can't confuse a state label for a path.
    $result = [ordered]@{ allow = @(); source = @(); status = 'absent' }

    # Order is the harness's merge order, least to most specific. The list is
    # positional only for readability - allow[] is a union, so precedence does
    # not change which forms are covered.
    # LABELS are relative to a named root, never absolute. The user-level file
    # is reported as '~/.claude/settings.json' rather than its resolved path
    # for two reasons: it is the only machine-identifying string this probe
    # would otherwise emit, and handoff files carrying probe output get
    # committed to repos; and one consistent shape is what makes the protocol's
    # "read any existing file missing from source[]" instruction mechanical
    # instead of a path-format comparison. The real path is still what gets
    # opened - this is a labelling change only.
    $userLabel = if ($UserSettingsPath -eq (Join-Path $HOME '.claude/settings.json')) {
        '~/.claude/settings.json'
    } else {
        $UserSettingsPath
    }

    $candidates = @(
        [ordered]@{ label = $userLabel;                    path = $UserSettingsPath }
        [ordered]@{ label = '.claude/settings.json';       path = (Join-Path $Root '.claude/settings.json') }
        [ordered]@{ label = '.claude/settings.local.json'; path = (Join-Path $Root '.claude/settings.local.json') }
    )

    $allow     = [System.Collections.Generic.List[string]]::new()
    $sources   = [System.Collections.Generic.List[string]]::new()
    $anyParsed = $false
    $anyFailed = $false

    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c.path)) { continue }
        if (-not (Test-Path -LiteralPath $c.path)) { continue }

        try {
            # -ErrorAction Stop is required here even though this script otherwise
            # runs under $ErrorActionPreference = 'Continue': Get-Content against a
            # path that is a directory raises a NON-terminating error, which
            # Continue prints to stderr and drops - try/catch never sees it - and
            # the read appears to "succeed" with nothing read. Forcing this one
            # call to Stop makes that failure catchable like any other.
            $raw = Get-Content -LiteralPath $c.path -Raw -ErrorAction Stop
            $s = $raw | ConvertFrom-Json -AsHashtable
            if ($null -eq $s -or $s -isnot [System.Collections.IDictionary]) {
                # ConvertFrom-Json on empty/whitespace-only input returns $null
                # WITHOUT throwing - a zero-byte or blank settings file would
                # otherwise sail past this point with $s silently null and land in
                # the success path below, contributing a real source path alongside
                # nothing at all. That reads as "we read this file and
                # nothing is allowlisted," which is false: we read nothing.
                #
                # A bare JSON scalar/array (0, false, "", [1,2,3]) is valid JSON,
                # so it also survives the null check above - but it isn't a
                # dictionary, so $s.ContainsKey() below would throw a NON-
                # terminating "does not contain a method" error that Continue
                # drops to stderr while $result quietly reports 'ok'. Same class
                # of bug, one layer down: reject anything that isn't an object
                # here too, before the ContainsKey calls can ever run.
                throw 'did not parse to a JSON object (empty, whitespace-only, or a bare scalar/array)'
            }

            # A malformed 'permissions' or 'allow' is a FAILURE TO DETERMINE,
            # not a determination of empty - so it throws to the catch below
            # and yields 'unknown' plus a loud error, exactly as a malformed
            # top level does. This validation lives INSIDE the try for that
            # reason: a throw out here would escape the function and break the
            # probe's never-throws/always-exit-0 contract.
            #
            # Skipping extraction instead (the first version of this code)
            # returned status 'ok' with the file listed in source[] and nothing
            # added to allow[]. That is the literal sentence the comment above
            # calls false: "we read this file and nothing is allowlisted", when
            # in fact we read it and could not understand it. The top-level
            # guard already chose 'throw' for the identical shape of bug; the
            # two now agree instead of differing arbitrarily.
            #
            # Rules stage in a PER-FILE list and are only merged after the file
            # validates. Adding straight to $allow would leave a partially-read
            # file's rules behind when a later key in the same file throws.
            $fileRules = [System.Collections.Generic.List[string]]::new()
            if ($s.ContainsKey('permissions')) {
                $perms = $s['permissions']
                if ($perms -isnot [System.Collections.IDictionary]) {
                    # {"permissions": "yes"} / 42 / [...] / null are valid JSON.
                    throw "'permissions' is not a JSON object (found $(if ($null -eq $perms) { 'null' } else { $perms.GetType().Name }))"
                }
                if ($perms.ContainsKey('allow')) {
                    $rules = $perms['allow']
                    # A bare string where an array belongs would otherwise land
                    # in allow[] as ONE entry holding the whole string, which
                    # reads as a single covered form and is not one.
                    if ($null -eq $rules -or $rules -is [string] -or $rules -isnot [System.Collections.IEnumerable]) {
                        throw "'permissions.allow' is not a JSON array (found $(if ($null -eq $rules) { 'null' } else { $rules.GetType().Name }))"
                    }
                    foreach ($rule in $rules) { $fileRules.Add([string]$rule) }
                }
            }
        } catch {
            $anyFailed = $true
            Add-ProbeError -Probe 'permissions' -Message "could not read/parse '$($c.path)' - the effective allowlist is UNKNOWN, not empty. Treat every command form as potentially prompting: $($_.Exception.Message)"
            continue
        }

        # Reaching here means the file parsed AND its permissions shape was
        # usable. Recording the source only now keeps source[] a list of files
        # actually understood, not merely opened.
        $anyParsed = $true
        $sources.Add($c.label)
        foreach ($rule in $fileRules) { $allow.Add($rule) }
    }

    # Concatenated, NOT de-duplicated, deliberately: the only question ever
    # asked of this list is "does any rule match the form I am about to run?",
    # and a duplicate rule cannot change that answer. De-duplicating would cost
    # a pass and buy nothing.
    $result.allow  = @($allow)
    $result.source = @($sources)
    # 'unknown' is tested FIRST and deliberately: one unreadable file among
    # three readable ones still means the merged list is short by an unknown
    # amount, and the protocol must treat that as undetermined rather than
    # trusting the part that parsed.
    $result.status = if ($anyFailed) { 'unknown' } elseif ($anyParsed) { 'ok' } else { 'absent' }
    return $result
}

$state = [ordered]@{
    schemaVersion = 1
    generatedAt   = (Get-Date).ToString('s')
    repoRoot      = $RepoRoot
    baseline      = $Baseline
    baselineValid = $baselineValid
    memoryPath    = $MemoryPath
    repo          = $repo
    webProjects   = @(Get-WebProjectBlock -Root $script:projectsRoot -Baseline $Baseline -BaselineValid $baselineValid)
    graphs        = @(Get-GraphBlock -Root $script:projectsRoot -StaleCommits $GraphStaleCommits)
    memory        = @(Get-MemoryBlock -Path $MemoryPath)
    operations    = (Get-OperationsBlock -Root $RepoRoot)
    permissions   = (Get-PermissionsBlock -Root $RepoRoot -UserSettingsPath $UserSettingsPath)
    config        = $script:vesperConfig
    errors        = $errors
}

$state | ConvertTo-Json -Depth 6
exit 0
