---
name: censor
description: >-
  Audit a web application against a web security baseline and produce a
  severity-ranked, baseline-mapped findings advisory. Runs deterministic scans
  (a read-only headers/TLS/exposed-path probe, a web-root inventory, semgrep
  baseline rules, and gitleaks secret detection) AND a reasoning source-review —
  single-session or a parallel reviewer fleet — that finds the access-control,
  IDOR, CSRF, and business-logic flaws the scanners cannot. The review is the
  point, not an add-on. Use ONLY when the user explicitly asks to audit or security-review a
  site, scan a web app for vulnerabilities, or check code against the security
  baseline — or invokes /censor:censor (bare /censor if installed as a copied skill).
  Do NOT auto-invoke on incidental mentions of
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
5. **Coverage honesty — never call a site "clean" or "secure" from a partial run.** This is the
   single most important rule. The deterministic scanners (probe, semgrep, gitleaks, web-root)
   are a *floor*, not a complete audit: they cannot find IDOR, missing-authorization, CSRF gaps,
   business-logic flaws, or eligibility-check gaps — those need the Stage-3 reasoning review. A
   run that finds a handful of line-level issues and stops has audited **the mechanical layer
   only**. Report exactly which stages/depth ran and, explicitly, **what was NOT checked**. If
   the reasoning review (Step 3, depth B/C) did not run, say plainly: "deterministic scan only —
   the access-control / CSRF / business-logic classes were not assessed; this is not a clean bill
   of health." A scan that returns half the findings and implies "you're good" is worse than no
   scan — it manufactures false confidence. When in doubt, under-claim coverage.
6. **A real audit is depth C (or B), not depth A.** Depth A (scanners only) is a triage pass, not
   an audit. To reproduce a thorough manual review, run the Stage-3 reasoning review — default to
   the depth-C reviewer fleet when the environment can spawn subagents. Do not let a depth-A run
   stand in for an audit.

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

**Verify the install works — `bash ${CLAUDE_SKILL_DIR}/scripts/selftest.sh`.** It runs the real
scan pipeline against a bundled known-bad corpus and confirms the expected rules fire (and that
clean code stays silent, and gitleaks/probe/web-root load). Run it once after install, especially
in a new environment: a scanner that silently returns zero findings is worse than none, and
CI-green on someone else's repo does not prove it works on yours. Exit 0 = functioning.

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
- **Depth** — **when the user asks for "an audit" / "a security review" / "scan my site", that
  means depth C** (or B if subagents can't spawn). Only drop to A if they explicitly want a quick
  triage. Do not default to the cheapest option: the whole value of this skill over a bare
  semgrep run is the reasoning review, and skipping it is how a scan comes back with half the
  findings and wrongly implies "you're good."
  - **A — Deterministic only:** probe + semgrep + gitleaks + web-root → findings list, NO reasoning
    review. A **triage floor**, explicitly *not* an audit — cannot find IDOR/CSRF/logic flaws.
    Never present an A run as a clean bill of health (guardrail 5).
  - **B — Deterministic + guided review:** A, then you personally read the flagged files **and the
    security-critical entry points** and work the full logic-bug checklist (Step 3) in this session.
  - **C — Deterministic + reviewer fleet (recommended for a real audit):** A, then spawn parallel
    subagents (Task tool), one per baseline dimension, each briefed as in Step 3. This is how the
    reference manual audits were performed; it is the way to reproduce (or beat) them. Needs an
    environment that can spawn subagents — if it can't, say so and fall back to B, not A.

Record the coverage you will actually achieve (e.g. "source + URL + deployed doc-root, depth C").
**If you cannot reach the deployed document root, or cannot run the reasoning review, state that
as a gap in the advisory — a source-only or scanner-only pass is not the audit the site owner
thinks they got.**

## Step 2 — Run the deterministic stages

**Easiest: the one-command orchestrator** runs every deterministic stage that applies and
writes JSON artifacts to an out-dir:
```
bash ${CLAUDE_SKILL_DIR}/scripts/run_deterministic.sh --source <path> --url <base-url> --out-dir <dir>
```
(Give `--source`, `--url`, and/or `--webroot`.) It runs the probe, web-root inventory, semgrep,
gitleaks, and — when the source contains `.ps1`/`.psm1` and `pwsh` is present — the PowerShell scan,
producing `probe.json`, `rules.json`, `secrets.json`, `ps.json`, `webroot.json`. Then read those
artifacts. Optional flags: **`--sarif`** also writes `semgrep.sarif`/`gitleaks.sarif` (GitHub
code-scanning / VS Code), and **`--fail-on error|high`** turns it into a CI gate (non-zero exit on
findings at/above that level). See `docs/CI-INTEGRATION.md` for a ready-to-use GitHub Actions
workflow — running Censor per-push is how the baseline gets enforced rather than audited by hand.

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
  entry points (auth, login/callback, DB layer, **every** admin/data/AJAX/`api/*` endpoint,
  upload handlers, and the DB schema/migrations). Work the **logic-bug checklist** — the classes
  static rules cannot judge. Don't just confirm the dimension exists; *investigate* it with the
  technique noted, because these are the findings a scanner-only pass misses:
  1. **SQL injection** — is user input actually bound, or int-cast/whitelisted? Confirm real vs. safe.
  2. **Access control / IDOR — the highest-yield reasoning check.** For every endpoint that
     reads OR writes a record: is the record scoped to the caller, or is an `id` from the request
     used directly? **Trace the WRITE path separately from the READ path** — a gated read
     (`review.php` checks eligibility) does *not* mean the write is gated. If eligibility lives in
     a shared helper or stored proc, **grep the whole schema/migrations to prove EVERY writer
     routes through it** — in one real audit the worst logic bug was a save-record
     stored proc that never called the eligibility function the read path used, letting any
     authenticated user forge a record for anyone.
     Small sequential IDs = trivial enumeration.
  3. **CSRF (§4) — check explicitly; it is easy to miss because "nothing looks wrong."** Does
     EVERY state-changing request (POST/PUT/DELETE, and anything that deletes/mails/exec's) carry
     and verify a CSRF token? `grep -ri csrf` the app — if it returns nothing, that IS the
     finding (the reference audit found an app with zero CSRF protection across 6 destructive
     endpoints). Are there state changes reachable via GET? Is `SameSite` set?
  4. **Missing eligibility / authorization gaps** — a sensitive action guarded only by a hidden
     form field, a UI that hides a button, or a client-side check. Re-derive the gate server-side.
     Endpoints that email/notify from a request-supplied recipient without an allowlist.
  5. **Auth / session** — session fixation (regenerate id at login?), OAuth `state` verified,
     cookie flags, and especially **any unsigned cookie / header trusted as identity** (auth
     bypass). Does logout destroy the server-side session, not just clear a cookie?
  6. **Secrets / config exposure + the DEPLOYED web root** — committed or web-served secrets;
     debug endpoints (`phpinfo`, env dumps). **Enumerate the deployed document root, not just the
     repo** (Stage 1.5): backups (`*.zip`/`_backups/`), data exports (`.csv`/`.xlsx`), `.sql`
     dumps, token files, installers — these exist only in the served directory and are often the
     single worst finding. Does the server serve `.txt`/`.json`/config as static files?
  7. **XSS / output** — untrusted values echoed unescaped, or `innerHTML` string-built;
     `href`/`src` from input without scheme-checking; framework escape-hatches (`Html.Raw`,
     `dangerouslySetInnerHTML`, `th:utext`, `v-html`).
  8. **File upload / traversal** — client filename trusted into a path; content validated by
     bytes not extension; download endpoints containing request paths.
  9. **Command / code execution** — `exec`/`shell_exec`/`proc_open`/`Runtime.exec`/`Process.Start`/
     PowerShell built from request data; deserialization of untrusted data; SpEL/OGNL; XXE.
  10. **Dead / debug code** — stale `*_V1`/`*_old`/`*Test` files still reachable (a `302` to login
      is NOT removal — a forged cookie may skip it); leftover diagnostics; `DEBUG=true`.
  11. **Headers / CSP / TLS** — from Stage 1, plus redirect-scheme downgrades and canonical host.
  12. **Error / info disclosure** — stack traces / SQL errors echoed; bootstrap `die()` returning
      200 instead of 503.
  Reference `${CLAUDE_SKILL_DIR}/SECURITY_BASELINE.md` (§1–§20) for the "why" and the fix pattern.

  **Before you conclude, run a completeness self-check** (this is the guard against a premature
  "looks clean"): *Which of the 12 dimensions did I actually investigate vs. skim? Did I check the
  WRITE path of every data endpoint, not just the read? Did I grep for CSRF? Did I enumerate the
  DEPLOYED root, not the repo? What could a manual auditor still find that I didn't look for?*
  Anything you did not genuinely assess goes in the advisory's coverage note as **not checked** —
  never silently omitted.

- **Depth C (recommended for a real audit):** Spawn one subagent per dimension above (Task tool),
  running them in parallel. **Brief each reviewer properly** — a thin brief yields a thin review:
  - the source path (+ the **deployed document-root path** for the web-root/secrets reviewer),
  - the specific dimension(s) it owns and the investigative technique above (e.g. the IDOR
    reviewer is told to trace write-vs-read and grep the migrations; the CSRF reviewer to grep the
    whole app and treat *absence* as the finding),
  - the relevant `SECURITY_BASELINE.md` sections, so it audits against the actual standard,
  - the guardrails: **read-only, file:line never values, verify-before-alarming**, and *return
    what it could NOT assess* alongside findings,
  - a instruction to return structured findings (severity, file:line/URL, one-line exploit, fix, §).
  Then dedupe across reviewers and run the same completeness self-check. If the environment can't
  spawn subagents, say so and fall back to Depth B — **never silently downgrade to A.**

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
