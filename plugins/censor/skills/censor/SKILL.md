---
name: censor
description: >-
  Audit a web application against a web security baseline and produce a
  severity-ranked, baseline-mapped findings advisory. Runs deterministic scans
  (a read-only headers/TLS/exposed-path probe, semgrep baseline rules, and
  gitleaks secret detection) plus an optional LLM source review at a chosen
  depth. Use ONLY when the user explicitly asks to audit or security-review a
  site, scan a web app for vulnerabilities, or check code against the security
  baseline — or invokes /censor. Do NOT auto-invoke on incidental mentions of
  security, auth, or a single bug; this is a heavy, deliberate operation.
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/scripts/check_deps.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/run_deterministic.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/probe.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/scan_webroot.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/scan_rules.sh *)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/scan_secrets.sh *)
  - Bash(pwsh -NoProfile -File ${CLAUDE_SKILL_DIR}/scripts/scan_ps.ps1 *)
  - Read
  - Grep
  - Glob
  - Write
  - Task
---

# Censor — audit a web app against the security baseline

You are performing an **authorized, read-only** security audit for an internal IT team.
This skill DETECTS problems and writes an advisory; it never exploits, never modifies the
target, and never edits the audited code. Follow these steps in order.

## Non-negotiable guardrails

1. **Read-only.** Only GET/HEAD requests to a live target; never send injection payloads,
   brute-force, or fuzz. Never modify the target site or its source.
2. **Never reproduce secret values.** If a scan surfaces a secret, refer to it by
   `file:line` (or URL) so the owner can rotate it — never paste the value into the advisory,
   your output, or any file.
3. **Verify before alarming.** A "downloadable / outsider-exploitable" claim is only
   reported as such after a Stage-1 probe confirms it (see Step 5). Otherwise label it
   "static-only, unverified." (This exists because a real audit once reported `.py` files as
   downloadable when they actually returned 404 — the probe caught it.)
4. **Advisory goes off-repo by default.** It names live exposures; do not write it inside a
   git working tree unless the user insists. Default to the user's Desktop or a path they give.
5. **Coverage honesty.** State exactly which stages/depth actually ran. If source is not
   reachable, say the result is black-box only — never present a shallow pass as a deep review.

## Step 0 — Check dependencies (and offer to install missing ones)

Run:
```
bash ${CLAUDE_SKILL_DIR}/scripts/check_deps.sh
```
It reports the detected OS, which tools are present (`curl`, `semgrep`, `gitleaks`, `openssl`),
and an `=== INSTALL COMMANDS ===` block giving the **OS-appropriate** install command for each
missing tool (`winget` on Windows, `brew`/`pipx` on Mac/Linux).

**Offer to install missing tools — with the user's confirmation, never silently:**
- For each missing tool whose install command is a real command (e.g. `winget install
  Gitleaks.Gitleaks`, `pip install semgrep`, `brew install semgrep`), ASK: "`<tool>` isn't
  installed — want me to run `<command>`?" Run it only on an explicit yes, then re-run
  `check_deps.sh` to confirm it took.
- **semgrep runs natively on Windows** (`pip install semgrep`, GA since CE Fall 2025 — needs
  Python 3.9+). Offer it like any other install; there is no longer a WSL/Docker requirement.
  (`scan_rules.sh` still auto-uses a Docker semgrep image if one is present and native semgrep
  isn't — a fallback, not the primary path.)
- **`MANUAL:` prefix** = no automatic install (e.g. curl/openssl ship with Git for Windows) —
  just surface the guidance.

**Then degrade gracefully** with whatever is available, and record what actually ran in the
final coverage note:
- No `curl` → Stage 1 (probe) unavailable.
- No `semgrep` (and no Docker fallback) → Stage-2 rule scan unavailable; lean harder on the LLM
  review and say so.
- No `gitleaks` → secret scan unavailable; lean on the `hardcoded-secret` semgrep rule + review.

## Step 1 — Establish target, depth, and coverage

If the user did not already provide them, ask (this is the "opening prompt"):

- **Target(s):** a **source path** (enables Stage 2 + 3), a **live URL** (enables Stage 1),
  and — **ask for this explicitly** — the **document root on disk** (enables Stage 1.5).
  All three is ideal. Note what you actually have.
- **The document root is worth asking for even when you already have source.** The source
  tree and the served directory are not the same thing: backups, data exports, archives and
  installers accumulate in the served directory and appear in no repository. In a real audit
  the worst finding existed only there. If the app is on a server you administer, ask for
  the deployed path (e.g. the IIS physical path or Apache `DocumentRoot`), not the repo.
- **Site-specific paths to probe** — **always ask this when you have a live URL.** The probe
  ships a *curated* list that finds CONVENTIONAL exposures (`.env`, `.git/config`,
  `phpinfo.php`); it cannot guess filenames someone invented. Ask: *"Any app-specific files
  or paths worth probing — token/credential files, admin or legacy pages, integration
  directories, anything a previous audit flagged?"* Feed them to `--paths`. If you have the
  source or a prior advisory, mine it for candidates first and offer them.
  _This exists because a real run found `phpinfo.php` on its own but missed a downloadable
  credential file and a live API token — both had site-specific names, and both were only
  re-found because an earlier audit had named them._
- **Depth** (default **B** if they don't care):
  - **A — Deterministic only:** probe + semgrep + gitleaks → findings list. No LLM review.
  - **B — Deterministic + guided review (default):** A, then you personally review the
    flagged files and run the logic-bug checklist below in this session.
  - **C — Deterministic + reviewer fleet:** A, then spawn parallel subagents (Task tool),
    one per baseline dimension, over the source. Most thorough; needs a capable environment.

Record the coverage you will actually achieve (e.g. "source + URL, depth B" or "URL only →
black-box, Stage 1 only").

## Step 2 — Run the deterministic stages

**Easiest: the one-command orchestrator** runs every deterministic stage that applies and
writes JSON artifacts to an out-dir:
```
bash ${CLAUDE_SKILL_DIR}/scripts/run_deterministic.sh --source <path> --url <base-url> --out-dir <dir>
```
(Give `--source`, `--url`, or both.) It runs the probe, semgrep, gitleaks, and — when the
source contains `.ps1`/`.psm1` and `pwsh` is present — the PowerShell scan, producing
`probe.json`, `rules.json`, `secrets.json`, `ps.json`. Then read those artifacts.

Or run the stages individually:

**Stage 1 (if a live URL is available):**
```
bash ${CLAUDE_SKILL_DIR}/scripts/probe.sh <base-url>
```
Reads security headers, TLS/HTTPS posture, and a curated exposed-path list (read-only,
status codes only — it never downloads secret bodies). Parse its JSON output.

**Stage 1.5 — web-root inventory (if you can reach the DOCUMENT ROOT on disk):**
```
bash ${CLAUDE_SKILL_DIR}/scripts/scan_webroot.sh <document-root-path>
```
**Run this whenever filesystem access is possible — it is the highest-yield deterministic
stage and nothing else substitutes for it.** Stages 1–3 all look at *code* or at *paths you
already know*; this one asks what is actually sitting in the served directory. It flags by
CATEGORY (archives, database dumps, data exports, credential files, backup directories,
installers, diagnostics, PHP inside statically-served files), assesses whether the server
config denies by default, and reports whether the document root is a dedicated `public/`
directory or the application directory itself.

*Why it exists:* in a real audit the single worst finding was a 289 MB
`FullBackup_<site>_<date>.zip` — a complete copy of the application including every
credential — sitting in the web root. No rule matches a `.zip`, and the probe's curated list
cannot guess that filename. **Only listing the directory finds it.** The same pass also
surfaced employee-data CSV exports and an `.xlsm` workbook, none of which any other stage
can see.

It reads names, sizes and extensions only — never file contents (the one exception is
`.html`/`.htm`/`.txt`/`.inc`, checked for embedded `<?php`, which are served as public static
text by definition). So it cannot leak a secret it discovers.

**Its findings mean "this file EXISTS in the root", not "this file is downloadable."**
Confirm each with a Stage-1 probe of the exact path (Step 5) before calling it
outsider-exploitable — handler mappings differ (`.json` is served, `.py` usually is not).

**Stage 2 (if a source path is available):**
```
bash ${CLAUDE_SKILL_DIR}/scripts/scan_rules.sh   <source-path>   # semgrep: PHP + Python + JS baseline rules
bash ${CLAUDE_SKILL_DIR}/scripts/scan_secrets.sh <source-path>   # gitleaks secrets
pwsh -NoProfile -File ${CLAUDE_SKILL_DIR}/scripts/scan_ps.ps1 -Path <source-path>   # PowerShell (PSScriptAnalyzer), if .ps1/.psm1 present
```
Collect the findings. Each semgrep hit carries the baseline `§` it maps to (in `metadata`).
The semgrep ruleset covers **PHP, Python, and JavaScript**; the PowerShell leg uses
PSScriptAnalyzer's security rules (tagged `[SECURITY]`).

## Step 3 — Stage 3 review (depth-dependent)

- **Depth A:** skip; go to Step 4 with the deterministic findings only.
- **Depth B:** Read the files the deterministic stages flagged, plus the security-critical
  entry points (auth, login/callback, DB layer, admin/data endpoints, upload handlers). Work
  the **logic-bug checklist** — the classes static rules cannot judge:
  1. **SQL injection** — is user input actually bound, or int-cast/whitelisted? Confirm real vs. safe.
  2. **Access control / IDOR** — does every record read/write scope to the caller or an
     explicit admin check? Are AJAX/`*_data.php`/`api/*` endpoints gated server-side, not just UI?
  3. **Auth / session** — session fixation (regenerate id at login?), OAuth `state`, cookie
     flags, and especially **any unsigned cookie / header trusted as identity** (auth bypass).
  4. **Secrets / config exposure** — committed or web-served secrets; debug endpoints
     (`phpinfo`, env dumps); does the web root serve `.txt`/`.json`/config as static files?
  5. **XSS / output** — untrusted values echoed unescaped, or `innerHTML` string-built;
     `href`/`src` from input without scheme-checking.
  6. **File upload / traversal** — client filename trusted into a path; content validated;
     download endpoints containing request paths.
  7. **Command execution** — `exec`/`shell_exec`/`proc_open`/PowerShell built from request data.
  8. **Dead / debug code** — stale `*_V1`/`*_old`/`Test` files still reachable; leftover
     diagnostics.
  9. **Headers / CSP / TLS** — from Stage 1.
  10. **Error / info disclosure** — stack traces / SQL errors echoed; bootstrap `die()`
      returning 200 instead of 503.
  Reference `${CLAUDE_SKILL_DIR}/SECURITY_BASELINE.md` for the "why" and the fix pattern.
- **Depth C:** Spawn one subagent per dimension above (Task tool), each briefed read-only with
  the source path + the relevant baseline sections, returning structured findings. Then
  dedupe across them. If the environment can't spawn subagents, tell the user and fall back
  to Depth B.

## Step 4 — Deduplicate, apply suppressions, rank

Merge deterministic + review findings; drop duplicates (same file:line/URL).

**Apply `.censorignore` suppressions.** If a `.censorignore` file exists at the audited
source root, read it and drop matching findings (this lets owners accept/mute known findings
so repeat audits stay quiet). Format — one rule per line, `#` starts a comment:
- `<rule-id>` — suppress that rule everywhere (e.g. `hardcoded-secret-define`).
- `<rule-id>:<path-glob>` — suppress that rule under matching paths (e.g. `cookie-as-identity:legacy/*`).
- `path:<glob>` — suppress all findings under a path (e.g. `path:vendor/**`).
Record how many findings were suppressed (and by which rules) in the advisory's coverage note
— suppressed ≠ absent, and the reader should know muting is in effect.

Then rank by severity (Critical → High → Medium → Low). For each finding keep: file:line or
URL, the baseline `§`, a one-sentence exploit/impact, and a fix direction.

## Step 5 — Verify exposure claims (the backstop)

For every finding you intend to label **outsider-exploitable / downloadable** (exposed
secret file, live debug endpoint, reachable legacy page), confirm it with a Stage-1 probe of
that exact path **before** marking it exploitable:
```
bash ${CLAUDE_SKILL_DIR}/scripts/probe.sh <base-url> --paths <(echo "/the/exact/path")
```
- 200 → confirmed; mark **[VERIFIED LIVE]** (status/type only — do not fetch the body).
- 404/403 → downgrade to "static/source finding, not outsider-reachable," and correct the claim.
If there is no live URL to probe against, mark such findings "source-only, live exposure
unverified" and say so.

## Step 6 — Write the advisory

Use `${CLAUDE_SKILL_DIR}/templates/advisory-template.md` as the structure. Produce:
- Findings ranked most-severe-first, each mapped to a baseline `§`, with file:line/URL,
  exploit sketch, fix direction, and a `[VERIFIED LIVE]` / `[static-only]` tag where relevant.
- A **"what's already solid"** section (balanced — this goes to a site owner, not a hit piece).
- A **suggested order** ending with the fix sequence.
- A **coverage note**: which stages/depth ran, and what was NOT covered.
Write it **off-repo** (default: the user's Desktop, filename `Censor_Advisory_<site>_<date>.md`
— ask the user for the date if you cannot generate one). Confirm the path with the user.

## Step 7 — Hand off

Summarize the top findings in chat, point to the file, and note it's advisory + read-only —
the owner takes it to their own session (or their own `/censor`) to fix. Never apply fixes
to someone else's code from here.
