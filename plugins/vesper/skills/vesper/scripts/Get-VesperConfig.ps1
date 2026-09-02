<#
.SYNOPSIS
  Load and validate a repo's Vesper configuration.

.DESCRIPTION
  Unlike Get-VesperState.ps1, this script THROWS. That division is deliberate:
  the probe reports facts and must never take down a departure sequence, while a
  missing or wrong config means the protocol cannot be trusted to describe this
  repo at all. Failing loudly here is the whole point - every failure found
  during the 2026-08-18 kit work was silent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

# -ConfigPath, when supplied, IS the file this loads - no derivation, no
# assumption that it lives under '.vesper/'. A relative value resolves
# against -RepoRoot so the conventional '-ConfigPath .vesper/config.json'
# works from any caller. Every refusal below names $path, so this is the
# ONLY place the path is decided: a caller who points at a custom file gets
# refusals naming THAT file, never the default one silently substituted in
# behind their back.
$path = if ($ConfigPath) {
    if ([System.IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath } else { Join-Path $RepoRoot $ConfigPath }
} else {
    Join-Path $RepoRoot '.vesper/config.json'
}

if (-not (Test-Path -LiteralPath $path)) {
    throw "No Vesper config at '$path'. Run /vesper setup in this repo first - it will detect what it can and ask about the rest. Vesper will not guess."
}

try {
    $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
} catch {
    throw "Vesper config at '$path' is not valid JSON: $($_.Exception.Message)"
}
if ($null -eq $cfg) { throw "Vesper config at '$path' is empty." }
if ($cfg -isnot [hashtable]) {
    throw "Vesper config at '$path' must be a JSON object at the top level, not a $($cfg.GetType().Name)."
}

# --- required sections: present, non-null, and an object - a present-but-null
# or non-object section is treated as missing rather than indexed into blind ---
foreach ($section in @('projects', 'deploy', 'maintenance', 'docs')) {
    if (-not $cfg.ContainsKey($section) -or $cfg[$section] -isnot [hashtable]) {
        throw "Vesper config is missing the required '$section' section. See the schema in the generalization design spec."
    }
}
if (-not $cfg.ContainsKey('graph')) { $cfg['graph'] = $null }

# --- retired keys: refuse rather than carry them inert -----------------------
# A key nothing reads is the exact failure this schema exists to prevent:
# present, non-null, and doing nothing, while the user believes it is in
# effect. Both of these were written by an earlier setup and consumed by
# nobody, so they are refused BY NAME with the fix in the message rather than
# ignored in silence.
if ($cfg.ContainsKey('identity')) {
    throw "config carries an 'identity' section, which is no longer part of the schema and was never read by anything. Delete it - the protocol refers to the user generically and needs no name. Re-run /vesper setup to regenerate a current config."
}
if ($null -ne $cfg.graph -and $cfg.graph -is [hashtable] -and $cfg.graph.ContainsKey('command')) {
    throw "config carries graph.command, which is no longer part of the schema and was never read by anything. Delete it - a graph-refresh COMMAND is environment-specific and belongs in your maintenance queue file (maintenance.queue), where it survives a skill upgrade. graph.dir stays: that is what the staleness probe reads."
}

# --- projects ---
if (-not $cfg.projects.ContainsKey('root') -or [string]::IsNullOrWhiteSpace($cfg.projects.root)) {
    throw "config projects.root must be a non-empty path relative to the repo root (use '.' for the root itself)."
}
$projRoot = Join-Path $RepoRoot $cfg.projects.root
if (-not (Test-Path -LiteralPath $projRoot)) {
    throw "config projects.root points at '$projRoot', which does not exist."
}

# projects.filter is a wildcard passed straight to Get-ChildItem -Filter. A
# non-string (7, true, an array) reaches that call as whatever PowerShell
# coerces it to and silently matches nothing - the deploy gate and the graph
# probe go quiet together, which is indistinguishable from a repo that
# genuinely has no projects. An empty or whitespace string is the same fault
# by a different route.
if ($cfg.projects.ContainsKey('filter') -and $null -ne $cfg.projects.filter) {
    if ($cfg.projects.filter -isnot [string]) {
        throw "config projects.filter must be a string wildcard (for example 'Project *') or null for no filter, not a $($cfg.projects.filter.GetType().Name)."
    }
    if ([string]::IsNullOrWhiteSpace($cfg.projects.filter)) {
        throw "config projects.filter is empty. Use null to treat every top-level directory as a project - an empty string would leave the key present but matching nothing, which is the failure mode this rejects."
    }
}

# --- deploy ---
if (-not $cfg.deploy.ContainsKey('script')) {
    throw "config deploy.script is required. Set it to the path WITHIN each project where a deploy script lives, or null if this repo has no deploy step."
}
if ($null -ne $cfg.deploy.script) {
    if ($cfg.deploy.script -isnot [string]) {
        throw "config deploy.script must be a path string relative to a project directory, or null if this repo has no deploy step, not a $($cfg.deploy.script.GetType().Name)."
    }
    if ([string]::IsNullOrWhiteSpace($cfg.deploy.script)) {
        throw "config deploy.script is empty. Set it to the path WITHIN each project where a deploy script lives, or null if this repo has no deploy step - an empty value would leave the item present but unable to run, which is the failure mode this rejects."
    }
}

# deploy.excludeRx selects which changed files the deploy gate ignores. The
# literal 'parse' means "read the pattern out of each deploy script at
# runtime"; any other string is used AS the pattern; null means no exclusions
# at all. A pattern that does not compile would throw inside the probe, which
# must never throw - so it is compiled HERE, where throwing is the contract.
if ($cfg.deploy.ContainsKey('excludeRx') -and $null -ne $cfg.deploy.excludeRx) {
    if ($cfg.deploy.excludeRx -isnot [string]) {
        throw "config deploy.excludeRx must be the literal 'parse', a regex string, or null, not a $($cfg.deploy.excludeRx.GetType().Name)."
    }
    if ([string]::IsNullOrWhiteSpace($cfg.deploy.excludeRx)) {
        throw "config deploy.excludeRx is empty. Use null for no exclusions, or 'parse' to read the pattern from each deploy script - an empty value would leave the key present and doing nothing, which is the failure mode this rejects."
    }
    if ($cfg.deploy.excludeRx -ne 'parse') {
        try { $null = [regex]::new($cfg.deploy.excludeRx) }
        catch { throw "config deploy.excludeRx is not a valid regular expression: $($_.Exception.Message). Use 'parse' to read the pattern from each deploy script instead, or null for no exclusions." }
    }
}

# --- graph: null means ABSENT, never 'present but inert' ---
if ($null -ne $cfg.graph) {
    if ($cfg.graph -isnot [hashtable]) {
        throw "config graph must be a JSON object with a 'dir', or null to disable graph maintenance entirely."
    }
    if (-not $cfg.graph.ContainsKey('dir') -or $cfg.graph.dir -isnot [string] -or [string]::IsNullOrWhiteSpace($cfg.graph.dir)) {
        throw "config graph.dir must name the per-project graph output directory. Set graph to null to remove graph maintenance entirely - an empty value would leave the item present but unable to run, which is the failure mode this rejects."
    }
}

# --- maintenance: the queue file the departure protocol is sent to READ ------
# This was the one declared path the loader did not check. Missing, null and
# empty all loaded clean, and the protocol then opened a file the loader had
# just confirmed valid and that did not exist - four lines below the docs.*
# checks that do exactly this. Same discipline, same shape of key.
if (-not $cfg.maintenance.ContainsKey('queue')) {
    throw "config maintenance.queue is required. Set it to the path of this repo's maintenance queue file (conventionally '.vesper/queue.md'), or null if this repo has no idle-work queue."
}
if ($null -ne $cfg.maintenance.queue) {
    if ($cfg.maintenance.queue -isnot [string]) {
        throw "config maintenance.queue must be a path string relative to the repo root, or null if this repo has no idle-work queue, not a $($cfg.maintenance.queue.GetType().Name)."
    }
    if ([string]::IsNullOrWhiteSpace($cfg.maintenance.queue)) {
        throw "config maintenance.queue is empty. Use null if this repo has no idle-work queue - an empty value would leave the item present but pointing nowhere, which is the failure mode this rejects."
    }
    $queuePath = Join-Path $RepoRoot $cfg.maintenance.queue
    if (-not (Test-Path -LiteralPath $queuePath)) {
        throw "config maintenance.queue declares '$($cfg.maintenance.queue)' but no such file exists at '$queuePath'. The departure protocol is sent to READ that file; declare null to remove the maintenance step, or create the file."
    }
}

# --- docs.operations: a DECLARED path must exist, relative to the repo root -
# This really is one root-relative file, unconditionally, and its validation
# is unchanged from before the projectMemory schema split below. ---
if ($cfg.docs.ContainsKey('operations') -and $null -ne $cfg.docs.operations -and $cfg.docs.operations -ne '') {
    if ($cfg.docs.operations -isnot [string]) {
        throw "config docs.operations must be a path string relative to the repo root, or null to skip it, not a $($cfg.docs.operations.GetType().Name)."
    }
    $docPath = Join-Path $RepoRoot $cfg.docs.operations
    if (-not (Test-Path -LiteralPath $docPath -PathType Leaf)) {
        throw "config docs.operations declares '$($cfg.docs.operations)' but no such file exists at '$docPath'. Declare null to skip it, or create the file."
    }
}

# --- docs.projectMemory: carries its own SCOPE - unlike docs.operations, this
# is genuinely not "one root-relative file" for every repo. Real users split
# four ways: one root-level file, one file each project keeps its own copy of,
# neither (no memory-doc convention, or a different tool entirely - a ticket
# system, a knowledge graph), or a stray combination of the first two. null
# must stay a first-class answer for "neither" - never "present but inert" -
# and a bare string is REFUSED outright: it cannot say which of the two scopes
# it means, and that exact ambiguity is the bug this schema exists to fix.
# Nothing published carries the old bare-string shape, so there is no
# migration cost to being strict about it now.
if ($cfg.docs.ContainsKey('projectMemory') -and $null -ne $cfg.docs.projectMemory) {
    $pm = $cfg.docs.projectMemory
    if ($pm -isnot [hashtable]) {
        # The bare-string case gets its OWN message: a filename is one step
        # from valid (someone has a real file on disk and just needs to say
        # which scope it lives under), so the refusal answers "which of the
        # two is my repo?" and points at the tool that already knows how to
        # answer it - the same pointer the config-absent refusal above gives.
        # A non-string, non-object value (a number, a bool, a bare array) is a
        # different mistake entirely and gets a message that does not claim a
        # "filename" was involved when there was none.
        if ($pm -is [string]) {
            throw "config docs.projectMemory must be an object - { `"scope`": `"root`", `"file`": `"<name>`" } for one repo-root file, or { `"scope`": `"project`", `"file`": `"<name>`" } for a file each project keeps its own copy of - or null to skip it entirely, not a bare string. A bare filename cannot say which of the two scopes it means - that ambiguity is exactly what this shape exists to remove. Run /vesper setup in this repo - it detects root files, per-project files, neither, or both, and writes the right scope for you."
        }
        throw "config docs.projectMemory must be an object - { `"scope`": `"root`", `"file`": `"<name>`" } for one repo-root file, or { `"scope`": `"project`", `"file`": `"<name>`" } for a file each project keeps its own copy of - or null to skip it entirely, not a $($pm.GetType().Name)."
    }
    # PLAIN statement assignment, not `$scope = if (...) {...} else {...}`. The
    # latter runs $pm.scope through the pipeline output stream as the value of
    # an if/else expression, and PowerShell UNWRAPS a single-element array
    # passing through that stream into its bare scalar element - so
    # { "scope": ["root"] } silently became the STRING 'root' by the time it
    # reached the check below, defeating the [string] type check entirely.
    # Proved by running this exact line in isolation: `$x = if ($true) {
    # @('root') }` yields a [string], while `$x = @('root')` or `if ($true) {
    # $x = @('root') }` both correctly keep it a [System.Object[]].
    $scope = $null
    if ($pm.ContainsKey('scope')) { $scope = $pm.scope }
    # -notin uses -eq semantics: case-INSENSITIVE, and true for a single-item
    # array whose one element equals a candidate (@('root') -notin @('root',
    # 'project') is $false, i.e. "accepted"). Both are real holes in a schema
    # whose whole point is refusing ambiguity - 'ROOT' and ['root'] would
    # otherwise silently behave as root. Requiring [string] closes the array
    # case; -cnotin (case-SENSITIVE) closes the casing case.
    if ($scope -isnot [string] -or $scope -cnotin @('root', 'project')) {
        $got = if ($null -eq $scope) { 'missing' } elseif ($scope -is [string]) { "'$scope'" } else { "a $($scope.GetType().Name)" }
        throw "config docs.projectMemory.scope must be 'root' or 'project', not $got."
    }
    if (-not $pm.ContainsKey('file') -or $pm.file -isnot [string] -or [string]::IsNullOrWhiteSpace($pm.file)) {
        throw "config docs.projectMemory.file must be a non-empty filename string. Set docs.projectMemory to null to skip it entirely - a present-but-empty file name would leave the item declared but unable to resolve, which is the failure mode this rejects."
    }

    if ($scope -eq 'root') {
        $docPath = Join-Path $RepoRoot $pm.file
        if (-not (Test-Path -LiteralPath $docPath -PathType Leaf)) {
            throw "config docs.projectMemory declares scope 'root', file '$($pm.file)', but no such file exists at '$docPath'. Declare docs.projectMemory null to skip it, or create the file."
        }
    } else {
        # scope 'project': at least one project directory must carry the file.
        # A declared file no project has is a typo, not a harmless miss - this
        # project's standing rule is to fail loudly rather than carry a
        # silently-inert setting, exactly like the 'root' branch above.
        #
        # Uses the SAME project selection the probe uses - projects.root (validated
        # above as $projRoot) + projects.filter, dot-directories excluded - via
        # the identical Get-ChildItem -Filter mechanism Get-ProjectDirs uses in
        # Get-VesperState.ps1, so a file this loader accepts is a file the probe
        # can actually find later.
        $pmDirs = if ($cfg.projects.filter) {
            Get-ChildItem -LiteralPath $projRoot -Directory -Filter $cfg.projects.filter -ErrorAction SilentlyContinue
        } else {
            Get-ChildItem -LiteralPath $projRoot -Directory -ErrorAction SilentlyContinue
        }
        $pmDirs = @($pmDirs | Where-Object { $_.Name -notmatch '^\.' })
        $found = @($pmDirs | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $pm.file) -PathType Leaf })
        if ($found.Count -eq 0) {
            throw "config docs.projectMemory declares scope 'project', file '$($pm.file)', but no project directory under '$projRoot' contains it. Declare docs.projectMemory null to skip it, or create the file in at least one project."
        }
    }
}

return $cfg
