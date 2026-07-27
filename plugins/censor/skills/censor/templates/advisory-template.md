# Security Advisory — <Site Name> (Censor, <date>)

**Nature:** advisory only, read-only audit. Nothing on the live server or in the source was
modified. Findings map to the `SECURITY_BASELINE.md`. **Secret values are never
reproduced** — exposed secrets are named by `file:line` so you can find and rotate them.
Findings verified live are tagged **[VERIFIED LIVE]** (HTTP status/type only — no secret
bodies were downloaded); everything else is static/source analysis.

**Coverage (read this before trusting the result):** <depth A/B/C + which stages ran — e.g.
"depth C: probe + web-root inventory + semgrep/gitleaks + a 6-reviewer source audit">.
**NOT covered / NOT a clean bill of health for:** <the dimensions you did not genuinely assess.
If the reasoning review (depth B/C) did NOT run, state it outright: "deterministic scan only —
access control / IDOR / CSRF / business-logic were NOT assessed." If the deployed document root
was not enumerated, say so. If subagents couldn't spawn and this fell back to B (or A), say so.>
This section is mandatory and must be honest — a scan that lists a few issues and implies the
rest is fine manufactures false confidence. Absence of a finding in a dimension you did not
examine is not evidence the dimension is safe.

---

## Fix today
<Outsider-exploitable-now items: downloadable secrets, live debug endpoints, auth bypass.
Each: what it is, the evidence (VERIFIED LIVE where probed), the one-line exploit, the fix,
and the baseline §. If none, say "Nothing in this tier.">

## High
<Serious but not instantly-exploitable-by-an-outsider. file:line, exploit, fix, §.>

## Medium
<Hardening. §.>

## Lower / cleanup
<Dead code, verbose errors, minor disclosure, version banners. §.>

---

## What's already solid
<Balanced — this goes to a site owner, not a hit piece. List the baseline items the site
passes: parameterized SQL, gated endpoints, correct escaping, env-based secrets, etc.
This section matters: it keeps the advisory credible and collaborative.>

## Suggested order
<Numbered remediation sequence, most-urgent first. Note rotations needed regardless of
exposure path (any secret that lived in a served file or committed source is rotated, not
just hidden).>

---

## Verification notes / caveats
- **Live-verified <date>:** <the exact paths/probes that returned what — status/type only>.
- **Corrected during verification:** <anything a scan claimed that a probe disproved>.
- **Path coverage is not exhaustive (state this whenever a probe ran).** Censor probes a
  *curated* path list plus any operator-supplied paths. It finds conventional exposures; it
  cannot know site-specific filenames. **A clean probe means "none of the tested paths were
  exposed" — never "nothing is exposed."** Only enumerating the web root from the filesystem
  or source gives that assurance. Say so explicitly: a site owner reading "clean" as an
  all-clear is the failure mode this note exists to prevent.
- **A `3xx` is not remediation.** A legacy page that redirects still exists; the redirect is
  the no-credential path. Report such paths as present, not as fixed.
- Static findings are from a point-in-time source copy — confirm each against live code
  before applying (line numbers may drift). This is advisory; nothing was applied.
