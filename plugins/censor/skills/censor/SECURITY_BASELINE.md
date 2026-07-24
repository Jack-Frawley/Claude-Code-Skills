# Security Baseline

A secure-by-default checklist, distilled from real production security audits across a mixed
estate of web apps and automation tooling. Each item was either a finding that had to be fixed or
a pattern that held up under review. Most are nearly free when baked in from commit 1 and
expensive to retrofit.

**Scope — this is not web-only.** It covers the whole surface that handles a secret or serves a
request: **PHP web apps · Python automation (API / cloud / SQL sync) · PowerShell tooling (user
lifecycle, deployment) · Linux/Apache · anything storing a credential or token.** §1–§13a are the
web request-path core; **§14–§17 are peers** (API/token lifecycle, cryptography, non-PHP code,
server/infra & at-rest), not appendices. New items are tagged **[DAY-1]** (hold from commit 1) or
**[HARDENING]**, with an OWASP/CWE ref and whether **Censor** can catch them statically (semgrep /
PSScriptAnalyzer / probe) or they need human/LLM review.

> **Mapping note:** validated against OWASP Top 10 (2021 + 2025) and ASVS 4.0. The core is strong
> on A01 (§6), A05 (§8/§8a/§9/§11), the 2025 "Exceptional Conditions" category (§12/§13), and Files
> (§7). §14–§17 + the expansions below close the thin areas: A02 crypto, A08 integrity, A09
> security logging, and the non-web / at-rest surfaces.

**Stack decision (per project):**
- **Framework (Laravel / Symfony / etc.)** for anything substantial — you get CSRF, an ORM
  (no raw SQL), auto-escaping templates, auth scaffolding, and env-based secrets *by default*.
  Most items below are then "already done — don't disable it."
- **Vanilla PHP** for small/simple tools — you are the security layer, so reuse a starter set
  of helpers (`csrf_field()`/`verify_csrf()`, `e()`, `sanitize_html()`, a secrets loader, a
  PDO wrapper). Keep them in a shared helpers file and an HTML-sanitizer module you copy into
  each project.

---

## 1. Secrets & config
- [ ] **No secret ever committed.** Secrets live in a git-ignored file (`config/secrets.php`)
      or env vars — added to `.gitignore` *before the first commit*.
- [ ] Commit a `secrets.example.php` template with placeholder values.
- [ ] App fails loudly (clear 500) if the secrets file is missing, rather than running insecure.
- [ ] Treat any secret that ever hit git history as compromised → rotate, don't just delete.
- _Framework: use `.env` + `config()`. Vanilla: a git-ignored `secrets.php` + `require` pattern._

## 2. Database access
- [ ] **Every** query with request data uses prepared statements / bound params — no string
      interpolation, ever.
- [ ] Dynamic `IN (...)` lists built from `?` placeholders, never values.
- [ ] `ORDER BY` / column names that vary by input use a **whitelist**, not interpolation.
- _Framework: use the ORM/query builder. Vanilla: PDO prepared statements only._

## 3. Output / XSS
- [ ] Escape on output by default (`htmlspecialchars(ENT_QUOTES)` / a helper like `e()`).
- [ ] Rich text (TinyMCE etc.) runs through an **allowlist sanitizer** before storing *and*
      rendering — never trust client-side sanitization. (Keep this in a dedicated HTML-sanitizer
      module.)
- [ ] In JS, set untrusted values via `textContent`, never `innerHTML` string-building.
- [ ] URLs from input/DB placed in `href`/`src` are scheme-checked (http/https/mailto only;
      block `javascript:`/`data:text-html`).
- [ ] **[DAY-1]** LDAP filters escape all user input (`ldap_escape($v, '', LDAP_ESCAPE_FILTER)`) —
      §2's prepared-statement rule has an LDAP twin if you query a directory. (A03, CWE-90; Censor: static.)
- [ ] **[DAY-1]** Never `unserialize()` request/DB-sourced data — use `json_decode`. No PHP
      object-injection surface. (A08, CWE-502; Censor: static.)
- [ ] **[HARDENING]** Positive input validation *beyond* escaping: validate type/length/range/format
      against an allowlist, server-side. Escaping is not validation. (A03 / ASVS V5, CWE-20; Censor: LLM-review.)
- _Framework: auto-escaping templates (Blade/Twig). Vanilla: escape at every echo._

## 4. CSRF
- [ ] A CSRF token on **every** state-changing request; verified with a timing-safe compare.
- [ ] **No state changes on GET** — links that mutate must be POST forms.
- _Framework: middleware does this. Vanilla: `csrf_field()` in every form + `verify_csrf()`._

## 5. Auth & sessions
- [ ] Prefer SSO/OAuth (your IdP) over hand-rolled passwords. Validate the OAuth `state` param.
- [ ] `session_regenerate_id(true)` across the login boundary (anti session-fixation).
- [ ] Session cookie: `Secure; HttpOnly; SameSite=Lax`, `use_strict_mode=1`.
- [ ] Gate every sensitive action **server-side** — never rely on a hidden menu/UI as the control.
- [ ] API tokens stored hashed (SHA-256+), shown plaintext once, revocable.
- [ ] **Session storage inside the project** from day 1: `session.save_path` → `storage/sessions`
      (guard: only `ini_set` it `if (is_dir(...))` after a `@mkdir`), plus explicit GC odds
      (`gc_probability 1 / gc_divisor 20`). A default system temp dir is invisible and never swept.
      Retrofitting this drops every live session once — free on day 1, a user-visible blip later.
- [ ] **`session_write_close()` on read-only JSON/polling endpoints** (after auth checks, before
      queries) — PHP file sessions serialize all requests per user; a 30s badge poll will queue
      behind real page loads without it.
- [ ] **[DAY-1] Session lifetime is bounded and logout truly invalidates.** Set idle + absolute
      timeouts; on logout destroy the **server-side** session (not just the cookie) and regenerate
      the id; rotate on privilege change. §5 nails fixation-*in*; this covers session-*out*.
      (A07 / ASVS V3, CWE-613; Censor: mixed — timeout settings static, "logout invalidates
      server-side" is review.)
- [ ] Credential policy, brute-force lockout, and MFA are the **IdP's** job, not the app —
      do NOT re-implement login lockout/password rules app-side (see §14 for what IS yours: token handling).

## 6. Access control / IDOR
- [ ] Every record read/write is scoped to the current user (or an explicit admin check) —
      never trust an `id` from the request to be "mine".
- [ ] Visibility filters (exclusion lists, role gates) applied to **all** endpoints that expose
      a record, not just the list view. (Classic bug: a hidden-user exclusion covered the list
      view but not profile/photo/info endpoints — enumerable by direct URL.)
- [ ] **A shared defense must live in ONE helper that every path routes through — new code that
      hand-rolls a query/send silently bypasses it.** Two findings in one audit were the same
      shape: a new form built its own directory `SELECT` without the shared exclusion clause
      (hidden users leaked into its dropdowns), and new email fields skipped the inline
      newline-normalizer. The fix both times was to push the defense into a shared helper so
      future endpoints inherit it for free. When you add a security filter or input sanitizer,
      make it a helper and grep for every raw call site — don't leave it inline where the next
      feature won't find it.
- [ ] **Excluding "gone" users from a directory sync: exclude the offboarding/retired org units
      explicitly, at the enumeration boundary, before allowed-unit matching** — don't rely on
      unit-targeting or an `accountEnabled` flag alone (retired accounts can stay enabled). Apply
      the same exclusion to EVERY directory/LDAP user pull (main list AND group-membership pulls).

## 7. File uploads
- [ ] Validate by **decode + re-encode** (e.g. GD → JPEG), not just MIME/extension — reject
      anything that won't decode (blocks SVG/polyglots).
- [ ] Store with randomized names; never trust the client filename for the path.
- [ ] Uploads dir is not script-executable; never serve user bytes under a guessed content-type.
- [ ] Enforce size caps server-side.
- [ ] **Unique filenames, never overwrite in place** (`time() . '_' . <sanitized>`): replacements
      get new URLs, which is what makes long static-cache TTLs (§13a) safe.
- [ ] **If you build a cleanup/orphan tool, enumerate EVERY writer of each managed dir** —
      including references buried in stored HTML bodies, not just dedicated columns. (Real
      near-miss: an orphan sweep knew the `featured_image` column but not rich-text body images in
      the same folder — "Scan & Delete" would have removed live article images.) Deletion tools
      must also re-derive their delete list server-side; never accept client-supplied paths.

## 8. HTTP headers & transport
- [ ] HTTPS everywhere; `Secure` cookies.
- [ ] **[DAY-1] HSTS** — `Strict-Transport-Security: max-age=31536000; includeSubDomains`. HTTPS +
      Secure cookies still leave a strip/downgrade window on the first request without it. (A02/A05,
      CWE-319; Censor: static/probe.)
- [ ] `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN` (or CSP `frame-ancestors`),
      `Referrer-Policy`.
- [ ] **CSP from day 1** — see §8a. It's the header item most often skipped and most expensive
      to add later.
- [ ] **[DAY-1] Redirects never downgrade the scheme.** A redirect issued from an HTTPS request
      must target `https://` (or be scheme-relative/path-only). An HTTPS→`http://` redirect is
      followed *in the clear*: cookies and any credentials submitted at the destination are exposed
      on-path, and HSTS on the origin host does not protect a different hostname. (A02/A05,
      CWE-319; Censor: probe — reported automatically.)
- [ ] **[DAY-1] One canonical hostname.** Pick the canonical host and redirect all others to it
      over HTTPS. Multiple live hostnames for one app fragment cookie scope and HSTS coverage, and
      make "is this our site?" unanswerable for users. (CWE-1385; Censor: probe.)
- [ ] **[DAY-1] No open redirects.** A redirect target taken from request data (`?next=`,
      `?returnUrl=`) must be validated against an allowlist or constrained to a same-origin path —
      never passed through as an absolute URL. Open redirects lend your domain's credibility to
      phishing and can leak tokens via the `Referer` header. (A01, CWE-601; Censor: static/review.)

## 8a. CSP-clean from day one (the invariant that's free to hold, expensive to establish)

A strict CSP is a **whole-codebase invariant**. Ship it in the *first* commit and it becomes
**self-enforcing**: the moment anyone writes an inline `style=`/`on*=`/`eval`, it visibly breaks in
the browser, so violations can never silently accumulate. Retrofit it and you're hunting down
everything that piled up while `unsafe-inline` quietly allowed it. This retrofit tax has been paid
more than once (inline JS on one site, inline CSS on another) — and both times it read as "not
worth restructuring right now" *in the moment*, which is exactly why it must be the default.

- [ ] **Ship the strict policy in commit 1** (tighten per project, but start here — no
      `unsafe-inline`, no `unsafe-eval`):
      `default-src 'self'; script-src 'self' 'nonce-{n}'; style-src 'self' 'nonce-{n}';
      img-src 'self' data:; object-src 'none'; base-uri 'self'; form-action 'self';
      frame-ancestors 'self'`. Keep a `$cspMode` kill-switch (`enforce`/`report`/`off`).
- [ ] **A per-request nonce helper** — memoized `base64(random_bytes(16))` per request — wired into
      the base layout so every `<script>`/`<style>` reflexively gets `nonce="..."` and the header
      emits the same value. (The header nonce must equal the tag nonce; verify once live.)
- [ ] **No inline `style=`.** Static → CSS classes. Discrete-dynamic (a *finite* set of colours /
      states) → classes (e.g. `bg-navy`, `badge-editor`). Continuous-dynamic (per-element px
      offsets/widths) → a **generated nonce'd `<style>`** emitting per-index rules, or CSS custom
      properties — never a `style=` attribute.
- [ ] **No inline `on*=` handlers** — delegate via `addEventListener` in nonce'd/external scripts.
- [ ] **No `eval` / `new Function` / string-form `setTimeout`/`setInterval`.**
- [ ] **Know the exemption that makes dynamic UI easy:** JS-set styles via the CSSOM
      (`el.style.x = …`) are **not** governed by `style-src` — only markup `style=` attributes and
      `<style>`/`<link>` elements are. So live/animated/dynamic styling can stay in JS untouched;
      you only ever convert what appears in the HTML *source*. (Corollary: when the server renders a
      colour via a class but JS later repaints via `.style`, have the JS strip the server class so
      clearing `.style` can't fall back to it.)
- [ ] **Smell test when auditing:** an attribute selector like `.x:not([style*="background"])` is a
      tell that CSS logic grew to depend on inline styles — it cannot exist in a CSP-clean codebase.

## 9. No debug/dead code in the web root
- [ ] No test/diagnostic endpoints in production. (Classic leak: `logintest.php`/`ldaptest.php`
      left in `public/` as unauthenticated directory-password oracles.) Delete scaffolding before deploy.
- [ ] Dead code paths (old auth, superseded sync scripts) deleted, not left "just in case."
- [ ] **[DAY-1] Secrets live OUTSIDE the web root.** Not "in a file the server happens not to
      serve" — physically outside the directory the web server can reach, or in env vars. Any
      credential inside the web root is one misconfiguration, one added MIME mapping, or one
      copied-in server config away from being downloadable. (A05, CWE-538; Censor: probe + static.)
- [ ] **[DAY-1] Deny-by-default static serving.** The web server must serve only the file types
      the app actually needs (`.php`, `.css`, `.js`, images, fonts). Everything else — `.txt`,
      `.json`, `.bak`, `.old`, `.sql`, `.config`, `.py`, `.log` — is denied by request filtering,
      not left to chance. **This is the structural control**: fixing individually-exposed files is
      whack-a-mole, whereas a deny-list config prevents the *next* one nobody thought to check.
      _Worked contrast: in one audited estate, a site with request filtering returned 403 for every
      dotfile probed, while a sibling site without it served a plaintext credential file and a live
      API token straight from its web root._ (A05, CWE-552; Censor: probe.)
- [ ] **A redirect is not remediation.** A superseded page that returns `302 → /login` still
      **exists**. The redirect is the *no-credential* path; a page that trusts a forged cookie or
      an unsigned header does not redirect at all. Superseded auth flows and legacy `*_V1`/`*_old`/
      `*Test` pages must be **deleted**, not left redirecting — and a scan showing `302` must never
      be recorded as "fixed." (A01/A07, CWE-1164; Censor: probe reports existence.)

## 10. Dependencies
- [ ] Use a lockfile (`composer.lock`) and keep dependencies current.
- [ ] `vendor/` handling consistent between repo and prod (both tracked, or both ignored —
      don't let prod silently drift from the repo).
- [ ] **[HARDENING]** CI runs a vuln gate (`composer audit` / `pip-audit` + Dependabot/Renovate); a
      known-vuln advisory flags or blocks the build — "prove current," not just "keep current."
      (A06 / A03:2025 Supply Chain, CWE-1104; Censor: it IS a CI check.)
- [ ] **[HARDENING]** Externally-sourced browser assets carry Subresource Integrity (SRI); server-
      only vendor libs (not in repo) have a recorded source + version + hash so a swap is detectable.
      (A08, CWE-829/494; Censor: SRI attribute static, provenance is review.)

## 11. Deploy hygiene
- [ ] Repo and prod never drift — deploy every committed change.
- [ ] Mind dependent-file ordering (e.g. deploy `secrets.php` *before* the `app.php` that requires it).
- [ ] Verify after every deploy: site loads (200/redirect, not 500) + spot-check security headers.
- [ ] After a **multi-file** deploy, confirm **each file** landed — grep the deployed copy for the
      specific change, don't just check the site is up. A scripted copy loop can silently skip one
      file and leave prod half-updated (real case: a `for`-loop `scp` skipped `index.php`, so a
      tightened CSP header didn't take effect until re-verified file-by-file).
- [ ] **Script the deploy gate on day 1** — one script that takes a commit range, scps only the
      changed files (excluding storage/, secrets), runs server-side `php -l` on every deployed PHP
      file, smoke-checks `/` + `/login`, and **warns about renamed/deleted files** whose old server
      copies stay live (scp never deletes — that's silent repo↔prod drift). Adapt per site.

## 12. Error handling / info disclosure
- [ ] `display_errors` off in production; log full detail server-side.
- [ ] Show users/admins a short message + correlation id — never a raw stack trace, SQL error,
      or upstream API response body.
- [ ] **Bootstrap failures must send a failure STATUS, not just failure text.** A
      `die("DB connection error")` emits HTTP 200 by default — uptime monitors read that as
      healthy while every user sees an error. `http_response_code(503)` before any bootstrap
      `die()`.

## 13. Failure visibility & operability (day-1 items, same retrofit economics as CSP)

A recurring audit finding: the request path gets hardened repeatedly while every
**background/failure path** stays silent — jobs, emails, and batch calls are written to succeed,
so nobody notices when they don't. Each item below is minutes of work in commit 1.

- [ ] **Every outbound HTTP call has timeouts** (`CURLOPT_CONNECTTIMEOUT` ~10s + `CURLOPT_TIMEOUT`
      per call class) and surfaces curl-level failure distinctly (return
      `['status','body','error']`, never a bare body). One shared request helper owns this so no
      call site can forget. Retry transient failures (token endpoints especially) with short
      backoff — but **skip the retry when the first attempt was slow** (timeout-class outage;
      retrying doubles a user-facing hang), and keep retry thresholds BELOW the timeout they guard.
- [ ] **Every scheduled job records its outcome** in a `sync_status`-style table
      (task PK, last_run_at, last_success_at, last_status, last_error, consecutive_failures)
      via a never-throws helper — and an admin diagnostics page shows OK/FAIL/**STALE** (stale =
      no success within 2× the job's cadence). A dead scheduled-task entry is otherwise invisible
      until users notice stale data.
- [ ] **Every user-triggered notification (email etc.) that fails is (a) recorded durably**
      (an `email_failures` table with context/recipients/subject/error, surfaced on diagnostics)
      **and (b) reflected honestly to the submitter** — "created, but the notification failed,
      alert X directly" beats a green success flash over a lost email.
- [ ] **Batch/sub-request failures are collected and reported, not swallowed** — a batch call
      returning an error must not read as "0 items processed, run OK."
- [ ] **A failed read must never masquerade as an empty result** — distinguish "the read failed"
      (auth blip, 500, exhausted retries) from "the read succeeded and found nothing." Conflating
      them is dangerous when the read gates a write/reconcile: a failed "fetch existing items"
      that returns `[]` makes a sync treat everything as new and **write duplicates**. (Real case:
      a swallowed read error → ~110 duplicate records + a skipped pre-write backup.) On a failed
      read, throw/skip that unit; leave existing state untouched; never fall through into the
      create/overwrite path.
- [ ] **Any auto-retrying trigger of an expensive downstream job needs a consecutive-failure cap**
      keyed to the request, with honest surfacing (banner + `/health`). Without it a persistently
      failing chain re-runs the expensive job every poll forever. **Count ALL non-success terminal
      states toward the cap, not just hard errors** — a "blocked/locked" state that keeps the job
      pending hammers just as hard. (Real case: a refresh cap first counted only `error`; a source
      workbook left open threw `blocked` after the costly upstream pull already ran, so it re-ran
      every minute for hours until `blocked` was folded into the cap.)
- [ ] **Fail loud over silently ingesting stale data** — a data-mirror/import that can't validate
      its newest source (missing sheet, structure drift) must block + surface a distinguishable
      status, never silently fall back to an older/stale source under a green "ok" row. The only
      tell of silent staleness is often a reviewer-only filename nobody checks.
- [ ] **Change-detection tokens (live-resync/polling) must be sensitive to identity, not just
      count** — a token folding `COUNT(*)` but not *which* rows exist misses a net-zero swap (delete
      X, add Y) inside one poll window, leaving other clients stale. Hash the ordered set (a crypto
      hash if collisions matter; `CHECKSUM_AGG` is an XOR fold that a colliding swap can cancel).
- [ ] **Client-side pollers must surface failures per independent stream** — never swallow fetch
      errors in an empty `.catch()`, and track consecutive failures PER stream (version-poll vs
      fragment-fetch): a shared counter that any stream's success resets hides a persistently
      broken sibling stream forever.
- [ ] **Log rotation from day 1**: size-based rotate-and-prune helper (5 MB / keep 5) swept over
      `storage/logs/*.log` by whichever job already runs most often. Append-forever logs are a
      disk-full incident with a long fuse (and archives must not re-match the sweep glob).
- [ ] **A `/health` endpoint from day 1**: unauthenticated, session/cookie-free (before
      `session_start()`), **detail-free** (`ok/fail` booleans only — db, storage-writable,
      job-freshness), HTTP 200/503, `Cache-Control: no-store`. Point monitoring at it the day
      the site goes live, not after the first outage.
- [ ] **[DAY-1] Security audit log** (the *other* half of this section — §13 above logs operational
      failures; this logs security events). Record authentication success/failure, access-control
      denials (§6), API-token use, and admin/privileged actions to a durable, queryable trail with
      actor + source IP + timestamp + correlation id. (A09, CWE-778; Censor: presence/review.)
- [ ] **[DAY-1] Log hygiene.** Never log secrets, tokens, passwords, full PII, or raw
      API/session bodies; neutralize newlines in any user value written to a log line (the §6
      email-newline normalizer generalizes). (A09, CWE-532/117; Censor: secret-in-log partly
      static, log-injection is review.)

## 13a. Performance defaults (free on day 1, measurable later)
- [ ] Static-file cache headers in `web.config` (`<clientCache cacheControlMode="UseMaxAge"
      cacheControlMaxAge="7.00:00:00" />`) **paired with** an mtime cache-buster helper on every
      static reference — the pair is safe only together (and only with unique upload filenames, §7).
- [ ] The cache-buster helper memoizes `filemtime` per request (a template calls it 100+ times).
- [ ] Dynamic image endpoints (avatars etc.) get a modest `max-age` (5–15 min) + ETag/304 —
      `max-age=0, must-revalidate` costs a DB hit per image per page view.
- [ ] Widgets rendered on every page (menus, sidebars) get one consolidated query (UNION), not
      one query per content type — and prove rewrites with a **parity test against the legacy
      implementation on live data** before shipping.

## 14. API, tokens & secret lifecycle

The token-file class — the highest-yield additions. A leaked bearer token is a persistent
credential; a leaked long-lived refresh token is worse. This is where a mixed estate most often
gets hurt in a real audit.

- [ ] **[DAY-1] Token/credential files never live under a web-served or repo root.** OAuth
      access/refresh tokens, `*_tokens.json`, `.cred`, service-account key files live **outside**
      every DocumentRoot/`public/` and outside the git tree — in a locked-down state dir
      (a per-user app-data path, a dedicated scripts dir, `/var/lib/<app>`) with least-privilege
      ACLs. *Why:* an OAuth token JSON left in a web root is directly downloadable — one GET =
      persistent API takeover. (A05/A01, CWE-538/522; Censor: static + probe.)
- [ ] **[DAY-1] No hardcoded secrets in source — any language.** DB passwords, client secrets, API
      keys, bearer tokens load from env/secret store, never string literals in `.py`/`.ps1`/`.php`.
      (Extends §1 beyond PHP.) *Why:* hardcoded DB passwords + client secrets across many source
      files mean one repo read leaks the estate. (A05, CWE-798; Censor: static — its strongest catch.)
- [ ] **[DAY-1] A secret that ever hit git history OR a web-reachable path is compromised → rotate.**
      Extends §1's git-history rule to at-rest/served exposure. *Why:* deleting the file doesn't
      un-leak tokens already pulled — revoke server-side + reissue. (A02, CWE-522; Censor: flags
      exposure, rotation is a human action.)
- [ ] **[DAY-1] Exposure response runs in this order — revoke, delete, rotate, then fix the cause.**
      When a credential is found exposed, the *first* action is server-side **revocation** (revoke
      the refresh token at the provider, roll the client secret at the identity provider), because
      that is the only step that invalidates copies already taken. Deleting the file only stops
      *new* copies and feels like remediation without being any. Then delete, then issue the
      replacement somewhere safe, then fix the structural cause (§9 deny-by-default) so the next
      file isn't exposed too. **Whether you believe anyone fetched it is irrelevant** — exposure is
      disclosure; there is usually no access log granular enough to prove otherwise. *Why:* a real
      audit found an identity-provider client secret and a live third-party API refresh token
      downloadable; "delete the files" would have left both credentials valid in whatever hands
      already held them. (A02/A07, CWE-522; Censor: flags the exposure — the revoke/rotate
      sequence is a human action.)
- [ ] **[DAY-1] TLS verification is never disabled.** No `verify=False` (requests/httpx), no
      `-SkipCertificateCheck`, no global cert-validation-off callback, no `curl -k`. A pinned CA
      bundle is fine; blanket-off is not. *Why:* turns every API call into a MITM opportunity;
      disproportionately common in "just make it work" glue. (A02, CWE-295; Censor: static.)
- [ ] **[DAY-1] Cert-auth lifecycle is monitored, not just created.** Every cert that headlessly
      authenticates automation (cloud-API / mail app-registration certs, HTTPS bindings) gets (a) a
      calendar reminder at issue and (b) a programmatic freshness check surfaced like §13's job
      status (warn at T-30d). *Why:* an unnoticed expiry silently breaks scheduled syncs + protocol
      flows. (A05, CWE-324; Censor: cert-store/`.pfx` `NotAfter` probe; the calendar step is judgment.)
- [ ] **[HARDENING] Request least-scope tokens; store the minimum.** OAuth scopes / API permissions
      are the narrowest that work (read-only where possible); don't persist a refresh token if the
      flow can re-auth interactively. *Why:* a leaked token's blast radius = its scopes.
      (A01, CWE-272; Censor: judgment — scope intent isn't statically obvious.)
- [ ] **[HARDENING] Integration credentials have a bounded lifetime and a known rotation cadence.**
      For every third-party integration (vendor APIs, identity providers, mail platforms) record:
      which credential, what scopes, where it's stored, when it expires, and who rotates it — in
      your ops inventory alongside the cert table. Prefer the shortest TTL the integration
      tolerates. *Why:* a leaked token's blast radius is its scopes **times its remaining
      lifetime**; a long-lived refresh token with no expiry and no owner is a permanent credential
      nobody is watching. An unrotatable credential you've forgotten about is indistinguishable
      from a backdoor. (A01/A05, CWE-522/672; Censor: judgment — inventory is a human record.)
- [ ] **[CONDITIONAL — only if an endpoint takes a URL/host from input] SSRF egress control.** A
      request built from user/DB-influenced input validates the destination against a host allowlist
      and refuses private/link-local/metadata ranges (`169.254.169.254`, `10/172.16/192.168`, `::1`).
      *Note:* if your outbound calls are to **fixed** hosts, this only bites if you ever accept a URL
      from input — don't mandate egress allowlists on fixed-host calls. (A10-2021 / A01-2025,
      CWE-918; Censor: LLM-review.)

## 15. Cryptography

- [ ] **[DAY-1] Password hashing = argon2id or bcrypt — never md5/sha1/sha256-raw/unsalted.** Any
      home-rolled credential store, any stack (`password_hash(PASSWORD_ARGON2ID)`, `argon2-cffi`/
      `bcrypt`). *Why:* fast/unsalted digests crack trivially; §5's SHA-256 rule is for API *tokens*,
      not user passwords. (A02, CWE-916; Censor: static, where any password is stored.)
- [ ] **[DAY-1] Security-bearing randomness uses a CSPRNG.** Tokens, nonces, IDs, salts, reset codes
      use `random_bytes`/`random_int` (PHP), `secrets` (Python), `RNGCryptoServiceProvider` (.NET) —
      never `rand`/`mt_rand`/`uniqid`/`microtime`, and `Get-Random` is **not** crypto. *Why:*
      predictable tokens = guessable sessions/reset links. A baseline often does this already (CSP
      nonces, §7 filenames) but never *states* it, so the next feature can regress silently.
      (A02, CWE-330/338; Censor: static.)
- [ ] **[DAY-1] Any cookie/header used as identity is integrity-protected (signed), not just present.**
      A value that asserts *who the user is* must be server-signed/verified (HMAC or framework-signed
      session), never a plain readable value the client can set. *Why:* a recurring finding — a
      legacy page trusted an **unsigned `$_COOKIE['user']` as identity** = one-request auth bypass.
      (A07/A01, CWE-565/807; Censor: judgment — proving "this value gates auth" is review; a probe can
      try forging.)
- [ ] **[DAY-1] Private keys / `.pfx` / key material stored with least-privilege ACLs, out of repo
      and web root.** Signing + cert-auth keys live in the OS cert store or an ACL'd path, never
      beside the code they authenticate. (Pairs with §14.) (A02, CWE-522/313; Censor: static/probe —
      flag `*.pfx`/`*.key`/`*.pem` in repo or under web root.)
- [ ] **[HARDENING] No hardcoded keys/IVs, no ECB, no static-IV reuse.** Symmetric crypto uses an
      authenticated mode (AES-GCM) with a per-message random IV and keys from the secret store (§14),
      never source literals; never `MODE_ECB`. *Why:* ECB leaks structure; hardcoded/reused keys/IVs
      void the encryption. (A well-formed AES-GCM implementation with a per-message IV is the model.)
      (A02, CWE-326/327; Censor: static — `MODE_ECB`, literal key/IV bytes near cipher calls.)

## 16. Non-PHP code security

Same principles as §1–§13, applied to Python automation and PowerShell tooling. Censor runs
semgrep (Python) and PSScriptAnalyzer (PowerShell), so most of these are statically checkable.

**Python (API integrations, SQL sync, emailers):**
- [ ] **[DAY-1]** No `shell=True` / `os.system` / `os.popen` with any non-constant argument;
      `subprocess` calls pass an **argv list**. (A03, CWE-78; Censor: static.)
- [ ] **[DAY-1]** No `eval` / `exec` / `compile` on external input — parse config/API responses,
      never evaluate them. (A03, CWE-95; Censor: static.)
- [ ] **[DAY-1]** No unsafe deserialization: no `pickle`/`marshal`/`shelve` across a trust boundary;
      `yaml.safe_load` only (never `yaml.load` without `SafeLoader`); prefer `json`. (A08, CWE-502;
      Censor: static.)
- [ ] **[DAY-1]** Parameterized DB queries in the SQL sync jobs (pyodbc/pymssql) — the §2 rule
      applies to the Python side too, not just PHP. (A03, CWE-89; Censor: static.)
- [ ] **[HARDENING]** Dependency + venv hygiene: pinned deps (hashes or a `uv`/pip-tools lockfile),
      a per-project venv (no system-site installs), a scheduled `pip-audit`. (A06, CWE-1104; Censor:
      detect missing lockfile / unpinned; `pip-audit` is the scan.)

**PowerShell (user lifecycle, deployment, protocol handlers):**
- [ ] **[DAY-1]** No `Invoke-Expression` (`iex`) on dynamic/external input — build calls with `&`/
      splatting/argument arrays. (A03, CWE-95; Censor: PSScriptAnalyzer `PSAvoidUsingInvokeExpression`.)
- [ ] **[DAY-1]** Credentials are `PSCredential`/`SecureString`, never plaintext; no
      `ConvertTo-SecureString -AsPlainText` from a source literal; scrub creds from transcripts.
      (A02, CWE-256/522; Censor: PSScriptAnalyzer `PSAvoidUsingPlainTextForPassword`/`PSUsePSCredentialType`.)
- [ ] **[DAY-1]** Custom protocol-handler input (`app://…`) is treated as untrusted: parse,
      allowlist-validate (expected GUID/username shape), reject anything else — never pass the raw
      URI into a command, path, or `iex`. *Why:* a registered handler is a browser-reachable entry
      point into a privileged local tool. (A03/A04, CWE-20; Censor: judgment — taint `args[0]`→sink.)
- [ ] **[HARDENING]** Scheduled-task service accounts run least-privilege (per-resource grants,
      batch-logon), not a shared domain-admin; documented in your ops inventory. (A01, CWE-269;
      Censor: judgment.)
- [ ] **[HARDENING]** Production/distributed scripts are Authenticode-signed and run under
      `AllSigned`/`RemoteSigned`; no `-ExecutionPolicy Bypass` baked into scheduled tasks or shortcuts.
      (A08, CWE-347; Censor: static — grep task defs/shortcuts for `-ep bypass`; signature presence.)

## 17. Server / infra & at-rest config

The exposed-source / `phpinfo()` class — applies to **Apache too**, not just IIS. This is the
server-config layer §9 doesn't reach.

- [ ] **[DAY-1] Web servers never serve source/config/data/backup by static path.** Deny-by-default
      for `.json .py .ps1 .txt .env .cred .bak .sql .git` and any config/secret file; block dotfiles
      and hidden segments. IIS: `<requestFiltering>` `hiddenSegments`/`fileExtensions`. **Apache:**
      `<FilesMatch>` + `Require all denied`, `Options -Indexes`, and confirm `.htaccess` is honored
      (`AllowOverride`). *Why:* downloadable token/secret files + served `phpinfo()`. (A05, CWE-548/538;
      Censor: probe — request sensitive extensions, expect 403/404, flag 200.)
- [ ] **[DAY-1] No `phpinfo()` / debug / env-dump endpoint in production, cross-stack.** Extends §9
      to Apache + IIS alike. *Why:* live `phpinfo()` leaks paths, versions, modules, sometimes secrets.
      (A05, CWE-215; Censor: static `phpinfo(` + probe `/phpinfo.php`,`/info.php`.)
- [ ] **[DAY-1] TLS everywhere + HSTS — no HTTP-only listener, including kiosks and "internal" boxes.**
      Every site redirects 80→443 and sends HSTS; a Linux/Apache kiosk is not exempt. *Why:* an
      HTTP-only kiosk means plaintext creds/session on a shared LAN. (A02, CWE-319; Censor: probe :80
      redirect + HSTS.)
- [ ] **[DAY-1] No unauthenticated endpoint returns person/staff data.** Any endpoint returning a
      directory requires an authenticated, authorized session — "it's behind the kiosk UI" is not a
      control. (Reinforces §6 across stacks.) *Why:* a kiosk autocomplete endpoint can leak the whole
      staff directory unauthenticated. (A01, CWE-306/862; Censor: probe — hit data endpoints with no
      session, flag 200-with-records.)
- [ ] **[HARDENING] Suppress server/version banners.** Apache `ServerTokens Prod`/`ServerSignature
      Off`; PHP `expose_php=Off`; strip IIS `X-Powered-By`/version headers. *Why:* banners hand
      attackers the CVE list; free to disable. (A05, CWE-200; Censor: probe headers.)
- [ ] **[HARDENING] Sensitive endpoints are network-reachability-scoped.** Admin/diagnostics/internal
      APIs are bound to a management VLAN or firewalled, not reachable from a kiosk/guest VLAN;
      document which VLAN each service answers on. *Why:* reachability is a control layer above app auth.
      (A05, CWE-668; Censor: judgment — needs topology.)
- [ ] **[HARDENING] Backups are off-host and access-controlled.** DB/secret backups don't share the
      source's volume/host, aren't under any web root, and carry restricted ACLs + at-rest encryption.
      *Why:* a backup beside the app inherits its exposure, and one disk/ransomware event takes both.
      (A05, CWE-538; Censor: judgment.)
