# Claude Code Skills

A small marketplace of [Claude Code](https://claude.com/claude-code) skills, built from
real work and sharpened by using them. Each one is installable on its own.

```
/plugin marketplace add https://github.com/Jack-Frawley/Claude-Code-Skills
```

| Skill | What it does | Install |
|---|---|---|
| **[Censor](#censor)** | Audits a web app against a security baseline and returns a severity-ranked advisory. Read-only. | `/plugin install censor` |
| **[Vesper](#vesper)** | Governs unattended end-of-day work: hand off on your way out, get one clean resume point in the morning. | `/plugin install vesper` |

---

## Censor


A **Claude Code skill** that audits a web application against a web security baseline and
produces a severity-ranked, baseline-mapped findings advisory. It runs **read-only** — it
detects and reports; it never exploits a target or edits the audited code.

Distilled from real-world production security-audit work into a repeatable tool: the same
three-stage sweep, every time, mapped to an explicit baseline.


### Why

Most small web shops have no repeatable way to hold a fleet of apps to a security standard —
audits are one-off and manual, and the standard itself tends to be a document people share
but never actually run against their code. Censor turns the standard into an executable tool:
point it at a site or a source tree, get back an advisory an owner can act on.

### How it works — three stages, deterministic-heavy

Most of the "scanning" needs no LLM. Value is front-loaded into deterministic stages; the LLM
is an optional deepening layer.

1. **Probe** (black-box, no LLM) — security headers, TLS/HTTPS posture, and a curated
   exposed-path list, via `curl`. Read-only; status codes only, never downloads response bodies
   (so an exposed secret file's contents are never captured).
2. **Rules** (source, no LLM) — [`semgrep`](https://semgrep.dev) with the baseline encoded as
   rules (`plugins/censor/skills/censor/rules/`), covering **PHP, Python, and JavaScript**;
   [`gitleaks`](https://github.com/gitleaks/gitleaks) for in-tree secrets; and
   [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) for **PowerShell**
   (`.ps1`/`.psm1`). **The baseline is an executable ruleset**, not just a document. Every rule
   is validated in CI (`semgrep --validate` + `--test` on each push).
3. **Reason** (source, LLM — optional, depth-selectable) — a guided source review for the logic
   bugs static rules can't judge: IDOR, auth bypass, missing checks. Runs in your own Claude
   session.

Every "outsider-exploitable" claim is confirmed by a live probe **before** it's reported as such
— reviewers propose, probes verify.

### Depth modes

Chosen at invocation (default **B**):

- **A — Deterministic only:** probe + semgrep + gitleaks → findings list.
- **B — Deterministic + guided review (default):** A, then a targeted source review of what the
  scans flagged, plus the logic-bug checklist.
- **C — Deterministic + reviewer fleet:** A, then parallel subagents, one per baseline dimension.

If source isn't reachable, it degrades honestly to a black-box (Stage 1) pass and says so.

### Requirements

- **[Claude Code](https://docs.claude.com/en/docs/claude-code)** (v2.1.x+).
- **Scanners:** `curl` (Stage 1), `semgrep` and `gitleaks` (Stage 2), `openssl` (optional, TLS
  cert expiry). On its first run the skill checks these, prints the **OS-appropriate** install
  command for anything missing (`winget` on Windows, `brew`/`pipx` on Mac/Linux), and **offers to
  install them for you** (with your confirmation). Any missing tool degrades gracefully.
- **Windows note:** `gitleaks` installs cleanly (`winget install Gitleaks.Gitleaks`), but
  **`semgrep` has no native Windows support** — run Censor from **WSL**, use **Docker**
  (`scan_rules.sh` auto-uses `semgrep/semgrep` if Docker is present), or run without semgrep
  (probe + gitleaks + the LLM review still apply).

### Install

**Via marketplace (recommended):**
```
/plugin marketplace add https://github.com/Jack-Frawley/Claude-Code-Skills
/plugin install censor
```

**Quick (local, for testing):** copy `plugins/censor/skills/censor/` into `~/.claude/skills/`.

### Usage

```
/censor                       # opens: asks for target + depth
/censor https://example.com   # black-box (Stage 1) if no source is given
/censor ./path/to/source      # source review (Stages 2–3)
```

The advisory is written **off-repo by default** (it names live exposures), and secret values are
never reproduced — secrets are referenced by `file:line` for rotation.

### Safety model

Read-only GET/HEAD only; no injection, brute-force, or fuzzing. Never modifies the target or its
code. Never reproduces secret values. Verifies exposure claims with a live probe before alarming.
Advisory-only — fixes happen in the owner's own session, by their choice.

### The baseline

`plugins/censor/skills/censor/SECURITY_BASELINE.md` is a general, secure-by-default web-security
baseline (OWASP-shaped: secrets, prepared statements, output escaping, CSRF, session hardening,
CSP, uploads, headers, error handling, failure-visibility, `/health`). The semgrep rules encode
its statically-detectable items; `rules/RULES.md` maps each rule to a baseline section **and**
documents what's LLM-only (IDOR, missing-check absences, CSRF) — so a green scan is never mistaken
for full coverage.

### Testing

```
bash tests/run_tests.sh
```
Runs `semgrep --test` over the ruleset (positive/negative fixtures), a `gitleaks` check against a
generated fixture, and `probe.sh --selftest`.


---

## Vesper

A **Claude Code skill** governing **unattended end-of-day work**. You hand off work on your
way out — *"heading home, keep going on the export bug"* — and Vesper runs a fixed protocol:
maximise what gets done without a human, never block on a question, defer only what genuinely
must wait, and leave exactly one committed resume point. The next morning a hook surfaces that
handoff before anything else happens, and the resume leg closes out every deferred decision.

### Why

The hour or two of session budget you waste walking out the door is real capacity, and
"I'll pick it up tomorrow" reliably loses the thread of what you were doing. The hard part
isn't working unattended — it's *ending* well: leaving a record precise enough that tomorrow
you resume rather than reconstruct.

### The two-signal trigger

It fires only when a departure cue and a continue-working instruction arrive **in the same
message**. A bare goodbye deliberately does nothing. A multi-hour autonomous session started
off "see you tomorrow" is a far worse failure than a missed trigger, so when in doubt it
stands down and you type `/vesper`.

### What it will and won't do while you're gone

**Will:** edit files, run tests, commit, push to origin, run read-only checks against
production.

**Won't:** deploy anywhere, write to production, send email, or take any outward-facing or
irreversible action. Hitting one of those doesn't stop the run — it becomes a deferred action
in the handoff carrying the exact command for you to run in the morning.

The line is repo state versus live-system state. Repo state is recoverable by anyone reading
git history; live-system state is not.

### Configuration

Almost everything environment-specific lives in one file, `.vesper/config.json`, written
for you:

```
/vesper setup
```

Setup is **attended by design** — the only part of Vesper permitted to ask questions. It
detects your repo's shape, prints every guess, asks before writing, and offers to install the
hooks. A wrong guess has to be visible now, not discovered three weeks later as a gate that
silently never fired.

The **protocol** — the prose the model actually follows — names no path, folder convention or
tool. The scripts do carry a few of the author's conventions as fallbacks for when no config
is present (`deploy_changed.ps1`, `graphify-out`, `OPERATIONS.md`); once you have a config,
yours replace them.

The one thing setup cannot write for you lives in the hook it installs: a regex naming your
deployable project paths, shipped as `PLACEHOLDER_PROJECT_A|PLACEHOLDER_PROJECT_B`. Replace it
or the deploy guard never fires — and it fails silently, which is the failure mode everything
else here exists to avoid. `Merge-VesperHooks.ps1` prints this when it finishes.

Then run the state probe and read its `errors[]` — that is the acceptance test:

```powershell
pwsh <skill dir>/scripts/Get-VesperState.ps1 -RepoRoot . -ConfigPath .vesper/config.json
```

It is read-only and always exits 0. Anything Vesper cannot do in your repo is named there —
an inert deploy gate, an unmatched project filter, an unreadable settings file.

### The hooks are not optional

Vesper's entire return leg lives in a `SessionStart` hook, because **a skill cannot fix a
session it never loads in** — the morning you most need the reminder is a morning you opened
Claude to work on something else, and the skill never fires. `/vesper setup` offers to install
them; take the offer.

### Requirements

PowerShell 7+, a git repository, and a session running with edits non-prompting
(`acceptEdits` or bypass). That last one is a precondition, not a preference: every step
writes files, so under the default `ask` mode the run stops on a prompt with nobody there.

### Usage

```
/vesper           # departure, standard mode
/vesper full      # departure, using the rest of the session budget
/vesper resume    # work through the open handoff
/vesper setup     # detect this repo and write .vesper/config.json (attended)
```

**Quick (local, for testing):** copy `plugins/vesper/skills/vesper/` into `~/.claude/skills/`.

## License

MIT — see [LICENSE](LICENSE).
