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
allowed-tools: >-
  Bash(bash ${CLAUDE_SKILL_DIR}/scripts/check_deps.sh*),
  Bash(bash ${CLAUDE_SKILL_DIR}/scripts/probe.sh*),
  Bash(bash ${CLAUDE_SKILL_DIR}/scripts/scan_rules.sh*),
  Bash(bash ${CLAUDE_SKILL_DIR}/scripts/scan_secrets.sh*),
  Bash(semgrep*), Bash(gitleaks*), Bash(curl*),
  Read, Grep, Glob, Write, Task
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

## Step 0 — Check dependencies

Run:
```
bash ${CLAUDE_SKILL_DIR}/scripts/check_deps.sh
```
It reports which tools are present (`curl`, `semgrep`, `gitleaks`, `openssl`). Use the result
to decide what can run and to degrade gracefully:
- No `curl` → Stage 1 (probe) unavailable.
- No `semgrep` → Stage-2 rule scan unavailable (fall back to `grep`-based spot checks +
  lean harder on the LLM review). Tell the user how to install it (the script prints guidance).
- No `gitleaks` → secret scan unavailable (lean on the `hardcoded-secret` semgrep rule + review).

## Step 1 — Establish target, depth, and coverage

If the user did not already provide them, ask (this is the "opening prompt"):

- **Target(s):** a **source path** (enables Stage 2 + 3) and/or a **live URL** (enables
  Stage 1). Both is ideal. Note what you actually have.
- **Depth** (default **B** if they don't care):
  - **A — Deterministic only:** probe + semgrep + gitleaks → findings list. No LLM review.
  - **B — Deterministic + guided review (default):** A, then you personally review the
    flagged files and run the logic-bug checklist below in this session.
  - **C — Deterministic + reviewer fleet:** A, then spawn parallel subagents (Task tool),
    one per baseline dimension, over the source. Most thorough; needs a capable environment.

Record the coverage you will actually achieve (e.g. "source + URL, depth B" or "URL only →
black-box, Stage 1 only").

## Step 2 — Run the deterministic stages

**Stage 1 (if a live URL is available):**
```
bash ${CLAUDE_SKILL_DIR}/scripts/probe.sh <base-url>
```
Reads security headers, TLS/HTTPS posture, and a curated exposed-path list (read-only,
status codes only — it never downloads secret bodies). Parse its JSON output.

**Stage 2 (if a source path is available):**
```
bash ${CLAUDE_SKILL_DIR}/scripts/scan_rules.sh   <source-path>   # semgrep baseline rules
bash ${CLAUDE_SKILL_DIR}/scripts/scan_secrets.sh <source-path>   # gitleaks secrets
```
Collect the findings. Each semgrep hit carries the baseline `§` it maps to (in `metadata`).

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

## Step 4 — Deduplicate + rank

Merge deterministic + review findings; drop duplicates (same file:line/URL). Rank by
severity (Critical → High → Medium → Low). For each finding keep: file:line or URL, the
baseline `§`, a one-sentence exploit/impact, and a fix direction.

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
