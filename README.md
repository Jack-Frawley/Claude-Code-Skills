# Censor

A **Claude Code skill** that audits a web application against a web security baseline and
produces a severity-ranked, baseline-mapped findings advisory. It runs **read-only** — it
detects and reports; it never exploits a target or edits the audited code.

Distilled from real-world production security-audit work into a repeatable tool: the same
three-stage sweep, every time, mapped to an explicit baseline.

## Why

Most small web shops have no repeatable way to hold a fleet of apps to a security standard —
audits are one-off and manual, and the standard itself tends to be a document people share
but never actually run against their code. Censor turns the standard into an executable tool:
point it at a site or a source tree, get back an advisory an owner can act on.

## How it works — three stages, deterministic-heavy

Most of the "scanning" needs no LLM. Value is front-loaded into deterministic stages; the LLM
is an optional deepening layer.

1. **Probe** (black-box, no LLM) — security headers, TLS/HTTPS posture, and a curated
   exposed-path list, via `curl`. Read-only; status codes only, never downloads response bodies
   (so an exposed secret file's contents are never captured).
2. **Rules** (source, no LLM) — [`semgrep`](https://semgrep.dev) with the baseline encoded as
   rules (`plugins/censor/skills/censor/rules/web-security-baseline.yml`) plus
   [`gitleaks`](https://github.com/gitleaks/gitleaks) for in-tree secrets. **The baseline is an
   executable ruleset**, not just a document.
3. **Reason** (source, LLM — optional, depth-selectable) — a guided source review for the logic
   bugs static rules can't judge: IDOR, auth bypass, missing checks. Runs in your own Claude
   session.

Every "outsider-exploitable" claim is confirmed by a live probe **before** it's reported as such
— reviewers propose, probes verify.

## Depth modes

Chosen at invocation (default **B**):

- **A — Deterministic only:** probe + semgrep + gitleaks → findings list.
- **B — Deterministic + guided review (default):** A, then a targeted source review of what the
  scans flagged, plus the logic-bug checklist.
- **C — Deterministic + reviewer fleet:** A, then parallel subagents, one per baseline dimension.

If source isn't reachable, it degrades honestly to a black-box (Stage 1) pass and says so.

## Requirements

- **[Claude Code](https://docs.claude.com/en/docs/claude-code)** (v2.1.x+).
- **Scanners:** `curl` (Stage 1), `semgrep` and `gitleaks` (Stage 2), `openssl` (optional, TLS
  cert expiry). Run `bash plugins/censor/skills/censor/scripts/check_deps.sh` to see what's
  present and how to install what's missing. Any missing tool degrades gracefully.

## Install

**Via marketplace (recommended):**
```
/plugin marketplace add https://github.com/Jack-Frawley/Claude-Code-Skills
/plugin install censor
```

**Quick (local, for testing):** copy `plugins/censor/skills/censor/` into `~/.claude/skills/`.

## Usage

```
/censor                       # opens: asks for target + depth
/censor https://example.com   # black-box (Stage 1) if no source is given
/censor ./path/to/source      # source review (Stages 2–3)
```

The advisory is written **off-repo by default** (it names live exposures), and secret values are
never reproduced — secrets are referenced by `file:line` for rotation.

## Safety model

Read-only GET/HEAD only; no injection, brute-force, or fuzzing. Never modifies the target or its
code. Never reproduces secret values. Verifies exposure claims with a live probe before alarming.
Advisory-only — fixes happen in the owner's own session, by their choice.

## The baseline

`plugins/censor/skills/censor/SECURITY_BASELINE.md` is a general, secure-by-default web-security
baseline (OWASP-shaped: secrets, prepared statements, output escaping, CSRF, session hardening,
CSP, uploads, headers, error handling, failure-visibility, `/health`). The semgrep rules encode
its statically-detectable items; `rules/RULES.md` maps each rule to a baseline section **and**
documents what's LLM-only (IDOR, missing-check absences, CSRF) — so a green scan is never mistaken
for full coverage.

## Testing

```
bash tests/run_tests.sh
```
Runs `semgrep --test` over the ruleset (positive/negative fixtures), a `gitleaks` check against a
generated fixture, and `probe.sh --selftest`.

## License

MIT — see [LICENSE](LICENSE).
