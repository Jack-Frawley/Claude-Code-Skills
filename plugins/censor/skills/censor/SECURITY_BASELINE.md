# Web Security Baseline

A secure-by-default checklist for new web projects. Every item is either a finding that had to be
fixed or a pattern that held up under audit — distilled from real production security-review
experience across small-to-mid PHP/web applications. Most of these are nearly free when baked in
from commit 1 and expensive to retrofit.

This is a general, organization-neutral baseline. It follows OWASP-shaped guidance and is intended
to be adopted or forked by any PHP/web shop as a starting point — tighten each item to your own
stack and threat model.

**Stack decision (per project):**
- **Framework (Laravel / Symfony / etc.)** for anything substantial — you get CSRF, an ORM
  (no raw SQL), auto-escaping templates, auth scaffolding, and env-based secrets *by default*.
  Most items below are then "already done — don't disable it."
- **Vanilla PHP** for small/simple tools — you are the security layer, so reuse a starter set
  of helpers (`csrf_field()`/`verify_csrf()`, `e()`, `sanitize_html()`, a secrets loader, a
  PDO wrapper). Maintain a shared, reusable set of these helpers across your projects.

---

## 1. Secrets & config
- [ ] **No secret ever committed.** Secrets live in a git-ignored file (`config/secrets.php`)
      or env vars — added to `.gitignore` *before the first commit*.
- [ ] Commit a `secrets.example.php` template with placeholder values.
- [ ] App fails loudly (clear 500) if the secrets file is missing, rather than running insecure.
- [ ] Treat any secret that ever hit git history as compromised → rotate, don't just delete.
- _Framework: use `.env` + `config()`. Vanilla: a git-ignored `secrets.php` loaded via `require`._

## 2. Database access
- [ ] **Every** query with request data uses prepared statements / bound params — no string
      interpolation, ever.
- [ ] Dynamic `IN (...)` lists built from `?` placeholders, never values.
- [ ] `ORDER BY` / column names that vary by input use a **whitelist**, not interpolation.
- _Framework: use the ORM/query builder. Vanilla: PDO prepared statements only._

## 3. Output / XSS
- [ ] Escape on output by default (`htmlspecialchars(ENT_QUOTES)` / a helper like `e()`).
- [ ] Rich text (TinyMCE etc.) runs through an **allowlist sanitizer** before storing *and*
      rendering — never trust client-side sanitization. (Use a server-side HTML sanitizer helper.)
- [ ] In JS, set untrusted values via `textContent`, never `innerHTML` string-building.
- [ ] URLs from input/DB placed in `href`/`src` are scheme-checked (http/https/mailto only;
      block `javascript:`/`data:text-html`).
- _Framework: auto-escaping templates (Blade/Twig). Vanilla: escape at every echo._

## 4. CSRF
- [ ] A CSRF token on **every** state-changing request; verified with a timing-safe compare.
- [ ] **No state changes on GET** — links that mutate (e.g. an "act-as / view-as" toggle) must be
      POST forms.
- _Framework: middleware does this. Vanilla: `csrf_field()` in every form + `verify_csrf()`._

## 5. Auth & sessions
- [ ] Prefer SSO/OAuth (e.g. an enterprise IdP) over hand-rolled passwords. Validate the OAuth
      `state` param.
- [ ] `session_regenerate_id(true)` across the login boundary (anti session-fixation).
- [ ] Session cookie: `Secure; HttpOnly; SameSite=Lax`, `use_strict_mode=1`.
- [ ] Gate every sensitive action **server-side** — never rely on a hidden menu/UI as the control.
- [ ] API tokens stored hashed (SHA-256+), shown plaintext once, revocable.
- [ ] **Session storage inside the project** from day 1: `session.save_path` → `storage/sessions`
      (guard: only `ini_set` it `if (is_dir(...))` after a `@mkdir`), plus explicit GC odds
      (`gc_probability 1 / gc_divisor 20`). The OS default temp path is invisible and never swept.
      Retrofitting this drops every live session once — free on day 1, a user-visible blip later.
- [ ] **`session_write_close()` on read-only JSON/polling endpoints** (after auth checks, before
      queries) — PHP file sessions serialize all requests per user; a 30s badge poll will queue
      behind real page loads without it.

## 6. Access control / IDOR
- [ ] Every record read/write is scoped to the current user (or an explicit admin check) —
      never trust an `id` from the request to be "mine".
- [ ] Visibility filters (exclusion lists, role gates) applied to **all** endpoints that expose
      a record, not just the list view. (Common bug: an exclusion filter covers list views but not
      the profile/photo/detail endpoints — records stay enumerable by direct URL.)
- [ ] **A shared defense must live in ONE helper that every path routes through — new code that
      hand-rolls a query/send silently bypasses it.** A recurring finding takes this shape: a new
      form builds its own `SELECT` against a directory table without the shared exclusion-filter
      helper (hidden users leak into its dropdowns), or a new email field skips the shared
      input-normalizer. The fix each time is to push the defense into a shared helper (an
      exclusion-clause helper, an input-cleaning helper) so future endpoints inherit it for free.
      When you add a security filter or input sanitizer, make it a helper and grep for every
      raw call site — don't leave it inline where the next feature won't find it.
- [ ] **Excluding "gone" users from a directory sync: exclude the offboarding/retired org units
      explicitly, at the enumeration boundary, before allowed-scope matching** — don't rely on
      directory-scope targeting or `accountEnabled` alone (retired accounts can stay enabled). Apply
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
      including references buried in stored HTML bodies, not just dedicated columns. (Classic
      near-miss: an orphan sweep knows the dedicated `featured_image` column but not rich-text body
      images stored in the same folder — a "Scan & Delete" would remove live in-article images.)
      Deletion tools must also re-derive their delete list server-side; never accept client-supplied
      paths.

## 8. HTTP headers & transport
- [ ] HTTPS everywhere; `Secure` cookies.
- [ ] `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN` (or CSP `frame-ancestors`),
      `Referrer-Policy`.
- [ ] **CSP from day 1** — see §8a. It's the header item most often skipped and most expensive
      to add later.

## 8a. CSP-clean from day one (the invariant that's free to hold, expensive to establish)

A strict CSP is a **whole-codebase invariant**. Ship it in the *first* commit and it becomes
**self-enforcing**: the moment anyone writes an inline `style=`/`on*=`/`eval`, it visibly breaks in
the browser, so violations can never silently accumulate. Retrofit it and you're hunting down
everything that piled up while `unsafe-inline` quietly allowed it. This retrofit tax is real and
recurring — inline JS on one site, inline CSS on another — and each time it reads as "not worth
restructuring right now" *in the moment*, which is exactly why it must be the default.

- [ ] **Ship the strict policy in commit 1** (tighten per project, but start here — no
      `unsafe-inline`, no `unsafe-eval`):
      `default-src 'self'; script-src 'self' 'nonce-{n}'; style-src 'self' 'nonce-{n}';
      img-src 'self' data:; object-src 'none'; base-uri 'self'; form-action 'self';
      frame-ancestors 'self'`. Keep a `$cspMode` kill-switch (`enforce`/`report`/`off`).
- [ ] **A `csp_nonce()` helper** — memoized `base64(random_bytes(16))` per request — wired into the
      base layout so every `<script>`/`<style>` reflexively gets `nonce="<?= csp_nonce() ?>"` and the
      header emits the same value. (The header nonce must equal the tag nonce; verify once live.)
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
- [ ] No test/diagnostic endpoints in production. (A leftover login-test or directory-test endpoint
      can become an unauthenticated password/directory oracle sitting in `public/`.) Delete
      scaffolding before deploy.
- [ ] Dead code paths (old auth, superseded sync scripts) deleted, not left "just in case."

## 10. Dependencies
- [ ] Use a lockfile (`composer.lock`) and keep dependencies current.
- [ ] `vendor/` handling consistent between repo and prod (both tracked, or both ignored —
      don't let prod silently drift from the repo).

## 11. Deploy hygiene
- [ ] Repo and prod never drift — deploy every committed change.
- [ ] Mind dependent-file ordering (e.g. deploy `secrets.php` *before* the `app.php` that requires it).
- [ ] Verify after every deploy: site loads (200/redirect, not 500) + spot-check security headers.
- [ ] After a **multi-file** deploy, confirm **each file** landed — grep the deployed copy for the
      specific change, don't just check the site is up. A scripted copy loop can silently skip one
      file and leave prod half-updated (e.g. a `for`-loop `scp` skips `index.php`, so a tightened
      CSP header doesn't take effect until re-verified file-by-file).
- [ ] **Script the deploy gate on day 1** — one script that takes a commit range, scps only the
      changed files (excluding storage/, secrets), runs server-side `php -l` on every deployed PHP
      file, smoke-checks `/` + `/login`, and **warns about renamed/deleted files** whose old server
      copies stay live (scp never deletes — that's silent repo↔prod drift). Build one deploy script
      per site and adapt it as needed.

## 12. Error handling / info disclosure
- [ ] `display_errors` off in production; log full detail server-side.
- [ ] Show users/admins a short message + correlation id — never a raw stack trace, SQL error,
      or upstream API response body.
- [ ] **Bootstrap failures must send a failure STATUS, not just failure text.** A
      `die("DB connection error")` emits HTTP 200 by default — uptime monitors read that as
      healthy while every user sees an error. `http_response_code(503)` before any bootstrap
      `die()`.

## 13. Failure visibility & operability (day-1 items, same retrofit economics as CSP)

A common audit pattern: the request path gets hardened repeatedly while every **background/failure
path** stays silent — jobs, emails, and batch calls are written to succeed, so nobody notices when
they don't. Each item below is minutes of work in commit 1.

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
- [ ] **Batch/sub-request failures are collected and reported, not swallowed** — a `$batch` call
      returning an error must not read as "0 items processed, run OK."
- [ ] **A failed read must never masquerade as an empty result** — distinguish "the read failed"
      (auth blip, 500, exhausted retries) from "the read succeeded and found nothing." Conflating
      them is dangerous when the read gates a write/reconcile: a failed "fetch existing items"
      that returns `[]` makes a sync treat everything as new and **write duplicates**. (A swallowed
      read error in a contact/record sync can produce ~100+ duplicate records plus a skipped
      pre-write backup.) On a failed read, throw/skip that unit; leave existing state untouched;
      never fall through into the create/overwrite path.
- [ ] **Any auto-retrying trigger of an expensive downstream job needs a consecutive-failure cap**
      keyed to the request, with honest surfacing (banner + `/health`). Without it a persistently
      failing chain re-runs the expensive job every poll forever. **Count ALL non-success terminal
      states toward the cap, not just hard errors** — a "blocked/locked" state that keeps the job
      pending hammers just as hard. (Classic case: a refresh cap first counts only `error`; a data
      source left locked/open throws `blocked` *after* the costly upstream pull already ran, so it
      re-runs every minute for hours until `blocked` is folded into the cap.)
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

## 13a. Performance defaults (free on day 1, measurable later)
- [ ] Static-file cache headers in `web.config` (`<clientCache cacheControlMode="UseMaxAge"
      cacheControlMaxAge="7.00:00:00" />`) **paired with** an `asset_url()` mtime cache-buster on
      every static reference — the pair is safe only together (and only with unique upload
      filenames, §7).
- [ ] `asset_url()` memoizes `filemtime` per request (a template calls it 100+ times).
- [ ] Dynamic image endpoints (avatars etc.) get a modest `max-age` (5–15 min) + ETag/304 —
      `max-age=0, must-revalidate` costs a DB hit per image per page view.
- [ ] Widgets rendered on every page (menus, sidebars) get one consolidated query (UNION), not
      one query per content type — and prove rewrites with a **parity test against the legacy
      implementation on live data** before shipping.
