# Censor — Stage-2 semgrep ruleset (`web-security-baseline.yml`)

Deterministic pattern rules that encode the **Web Security Baseline**
(`../SECURITY_BASELINE.md`) for the Censor security-audit skill. These are **defensive** rules:
they DETECT insecure patterns and flag them for human/LLM review. They do not exploit anything.

Stance: **precision-with-some-false-positives over misses.** Where a rule is inherently noisy it is
scored WARNING/INFO and says so in its `message`. A false positive means "a human should look at
this line," which is an acceptable cost for a review tool.

## Rule catalog

| Rule id | Baseline § | Severity | Enforces / detects |
|---|---|---|---|
| `sqli-string-interpolation` | §2 Database access | ERROR | Request data (`$_GET`/`$_POST`/`$_REQUEST`/`$_COOKIE`) interpolated or concatenated into SQL reaching `->query`/`->exec`/`mysqli_query`/`sqlsrv_query` or a `$sql`/`$query` var — use prepared statements. |
| `php-display-errors-on` | §12 Error handling | WARNING | `ini_set('display_errors', 1/'On'/true)` — leaks stack traces/SQL/paths in prod. |
| `php-error-reporting-all` | §12 Error handling | INFO | `error_reporting(E_ALL)` — context signal; dangerous only when paired with display_errors on. |
| `session-cookie-insecure` | §5 Auth & sessions | WARNING | `'secure' => false` in `session_set_cookie_params`, or `session.cookie_secure` disabled — session cookie must be Secure. |
| `cookie-as-identity` | §5 Auth & sessions | ERROR | A `$_COOKIE[...]` value assigned to an identity var (`$user`, `$username`, …) — the legacy cookie-trust auth-bypass class. Best-effort; FP acceptable. |
| `phpinfo-call` | §9 No debug/dead code | ERROR | Any `phpinfo(...)` call — config/env dump in the web root. |
| `var-dump-getenv` | §9 / §1 | ERROR | `var_dump`/`print_r`/`echo` of `getenv()`/`$_ENV` — env-leaking debug endpoint (an env-dump debug endpoint). |
| `echo-request-unescaped` | §3 Output/XSS | ERROR | `echo`/`print`/`<?=` of `$_GET`/`$_POST`/`$_REQUEST` not wrapped in `htmlspecialchars`/`htmlentities`/`h(`/`e(` — reflected XSS. |
| `eval-or-dynamic-exec` | §8a CSP-clean/no-eval | ERROR | `eval(`, `assert($var)`, `create_function(`, or `call_user_func(_array)` on request data — dynamic code execution. |
| `extract-request` | §8a | ERROR | `extract($_GET/$_POST/$_REQUEST/$_COOKIE)` — variable injection. |
| `error-detail-echoed` | §12 Error handling | WARNING | `die`/`echo`/`print_r` of `$e->getMessage()`, `sqlsrv_errors()`, or `mysqli_error()` — leaks exception/DB detail to output. |
| `upload-trusts-client-name` | §7 File uploads | WARNING | `move_uploaded_file(..., ... $_FILES[...]['name'] ...)` — client filename used in the destination path. |
| `hardcoded-secret-define` | §1 Secrets & config | WARNING | `define('*_SECRET'/'*_KEY'/'*_PASSWORD', '<literal>')` or `$*password = '<literal>'` — hardcoded-looking secret. |
| `innerhtml-string-build` | §3 Output/XSS (JS) | WARNING | `.innerHTML`/`.outerHTML` assigned a string built by concatenation or a template literal with interpolation — DOM XSS. `languages: [javascript, typescript]`. |
| `php-unserialize-untrusted` | §3/§14 | ERROR | `unserialize()` of `$_GET/$_POST/$_REQUEST/$_COOKIE` — PHP object injection / RCE. Use `json_decode`. CWE-502. |
| `php-ldap-injection` | §3 | ERROR | Request data in an LDAP filter (`ldap_search`/`list`/`read`) not wrapped in `ldap_escape` — LDAP injection. CWE-90. |
| `php-weak-hash` | §15 Crypto | WARNING | `md5()`/`sha1()`/`hash("md5"/"sha1")` — weak for passwords/tokens (use `password_hash` ARGON2ID). CWE-916/328. |
| `php-weak-random-token` | §15 Crypto | WARNING | `rand()`/`mt_rand()`/`uniqid()` — not a CSPRNG; for tokens/nonces/salts use `random_bytes`/`random_int`. CWE-330/338. |
| `php-open-redirect` | §8 Transport | WARNING | `header()` built from `$_GET`/`$_POST`/`$_REQUEST`/`$_COOKIE` — open redirect / header injection; allowlist the target or use a same-origin path. CWE-601. |
| `php-debug-constant-true` | §12 Info-disclosure | WARNING | `const DEBUG = true` / `define('DEBUG', true)` — app debug flag left on; typically switches error handlers to raw exception text (DSN, server, SQL errors). CWE-489/209. |

**Rule count: 23 PHP+JS** (19 PHP, 4 JS/TS) + 11 Python + 5 Java + 6 C# + 3 Dockerfile = **48 total**
(see the per-language sections below). Fixtures for the crypto/injection additions:
`tests/php_unserialize.php`, `tests/php_ldap.php`, `tests/php_crypto.php`.

## Test fixtures

Native semgrep test fixtures live in `tests/`, using the annotation convention: a line that SHOULD
match is preceded by `// ruleid: <rule-id>`, a line that should NOT match by `// ok: <rule-id>`.
Every rule has at least one positive and one negative case. Fixtures are grouped by topic:

| Fixture | Rules exercised |
|---|---|
| `tests/sqli.php` | `sqli-string-interpolation` |
| `tests/config.php` | `php-display-errors-on`, `php-error-reporting-all`, `session-cookie-insecure` |
| `tests/auth.php` | `cookie-as-identity` |
| `tests/debug.php` | `phpinfo-call`, `var-dump-getenv` |
| `tests/xss.php` | `echo-request-unescaped` |
| `tests/dynexec.php` | `eval-or-dynamic-exec`, `extract-request` |
| `tests/errors.php` | `error-detail-echoed` |
| `tests/upload.php` | `upload-trusts-client-name` |
| `tests/secrets.php` | `hardcoded-secret-define` (values are obvious fakes — `REDACTED_FAKE_SECRET`) |
| `tests/innerhtml.js` | `innerhtml-string-build` |

Run the built-in test runner from the `rules/` directory:

```
semgrep --test --config web-security-baseline.yml tests/
```

> **`semgrep --test` run is PENDING.** semgrep was not installed in the authoring environment, so
> the rules and fixtures were written by hand and have **not** been executed yet. Run the command
> above before relying on the ruleset. If your semgrep version pairs tests by *filename* rather than
> by rule-id annotation, rename each fixture to share the config basename (or split the yaml). The
> annotation-by-id convention above matches current semgrep behavior.

### Patterns to double-check on that first run

These use constructs whose exact semgrep behavior should be verified against a live run:

- **Deep-expression operator `<... $_GET[...] ...>`** — used across `sqli-string-interpolation`,
  `echo-request-unescaped`, `error-detail-echoed`, `var-dump-getenv`, `upload-trusts-client-name`,
  `cookie-as-identity`. This is standard semgrep, but confirm it matches request data in *any*
  argument position (not just the first).
- **PHP string-interpolation matching** — the `$sql = "...{$_REQUEST['id']}"` positive in
  `sqli.php` relies on semgrep finding a superglobal inside a double-quoted interpolated string.
  Concatenation cases are more certain; the interpolation case is the one to verify.
- **PHP superglobal literals in patterns** (`$_GET`, `$_ENV`, `$_FILES[...]['name']`) — semgrep
  treats these as literals (as the public `p/php` registry does), not metavariables; confirm.
- **`session_set_cookie_params([..., "secure" => false, ...])`** — array-with-key pattern; verify
  the `...` before/after the key element behaves as expected.
- **`assert($X)`** — matches `assert` with a single argument (intentionally broad; `assert()` is a
  known eval-like sink). Confirm it does not over-match on multi-arg `assert()` in your code.
- **JS template literal `` `...${...}...` ``** in `innerhtml-string-build` — verify the interpolation
  ellipsis matches, and that the plain-string `ok` case (no `${}`) is correctly excluded.
- **`hardcoded-secret-define` metavariable-regex** — the value regex `^['"].+['"]$` is meant to fire
  only on string *literals* (excluding `getenv(...)`); the `$VARNAME = $VAL` branch is broad and
  filtered by name regex `(?i)(password|passwd|secret)`. Confirm both branches behave.

## Covered by Stage 1.5 (web-root inventory), not by rules

`scripts/scan_webroot.sh` covers a class no ruleset can reach, because the finding is not in
the code — it is a **file sitting in the served directory**. A rule can only match text it is
pointed at; a probe can only ask about paths it already knows. Neither enumerates the root.

| Category | Example that a real audit found |
|---|---|
| `archive` | a 289 MB `FullBackup_<site>_<date>.zip` — the whole app plus every credential |
| `data-export` | employee-data `.csv` exports; a staff workload `.xlsm` |
| `db-dump` | `.sql` schema files |
| `credential-file` | `*tokens*.json`, `Secret Value.txt`, `.env`, private keys |
| `backup-dir` | `_backups/` whose `.php` contents still **execute** |
| `source-disclosure` | `<?php` inside a `.html` file — served as text, source delivered verbatim |
| `root_structure` | the document root **is** the application directory (no `public/` boundary) |
| `server_config` | `web.config` with no `<requestFiltering>` — the structural cause |

Severity is coupled to structure: a missing deny-list on a dedicated `public/` root is
MEDIUM (defence-in-depth); on a root that *is* the app directory it is HIGH (the cause).

Stage 1.5 reports **existence**, not reachability — always confirm with a Stage-1 probe of the
exact path before calling something downloadable (`.json` is served; `.py` usually is not).

## Not covered by rules (LLM-only — need human/LLM judgment, not static patterns)

Static patterns can only catch syntactic shapes. The following baseline items require semantic or
contextual reasoning and are left to Censor's LLM stage (or a human reviewer). They are called out
so nobody mistakes a green semgrep run for full baseline coverage:

- **IDOR / missing ownership scoping (§6)** — "is this record read/write scoped to the current
  user?" A `WHERE id = ?` query is *syntactically* fine; whether the `id` is authorized for this
  user is a semantic question no pattern can answer.
- **Missing eligibility / server-side gate (§5, §6)** — a sensitive action guarded only by a hidden
  menu/UI, or a new endpoint that hand-rolls a query and bypasses a shared filter
  (`staff_exclude_clause()`), is an *absence* of a check — undetectable by "look for pattern X."
- **Is-a-cookie-trust-actually-a-bypass (§5)** — `cookie-as-identity` flags the shape, but whether a
  given cookie read is a real auth bypass vs. a harmless preference read needs judgment.
- **Absence of `session_regenerate_id(true)` across the login boundary (§5)** — proving something is
  *missing* at the right place is not a pattern match.
- **Missing CSRF token / state-change on GET (§4)** — requires understanding which requests are
  state-changing and whether a token is verified with a timing-safe compare.
- **CSP completeness / inline `style=`/`on*=` accumulation (§8, §8a)** — whether the deployed CSP is
  actually strict, and whether inline handlers exist across templates, is a whole-codebase +
  server-header question beyond single-file patterns.
- **Upload decode+re-encode validation, size caps, non-executable upload dir (§7)** — the *absence*
  of proper validation, not a bad call, is what matters.
- **URL scheme-checking for `href`/`src` from input (§3)** — needs dataflow + intent.
- **Failure-visibility / operability items (§13)** — timeouts on outbound calls, job-outcome
  recording, honest failure surfacing, failed-read-vs-empty-result, log rotation, `/health` — these
  are architectural presence/absence checks, not code smells.
- **Secrets in git history (§1)** — `gitleaks` is the primary secret scanner (history-aware);
  `hardcoded-secret-define` is only a lightweight in-file complement and cannot see history.
- **Prepared-statement dynamic `IN (...)` and `ORDER BY` whitelisting (§2)** — a `?`-list or a
  whitelisted column is correct; distinguishing it from interpolation reliably needs semantic
  reasoning beyond the coarse `sqli-string-interpolation` shape.

---

# Python rules (`python-baseline.yml`)

A companion ruleset covering the Python-specific insecure patterns the PHP-first baseline does not
enumerate directly. Same stance: **precision-with-some-false-positives over misses**; noisy rules
are WARNING/INFO and say so in the message. § numbers map to the closest `SECURITY_BASELINE.md`
section (the baseline is PHP-shaped, so several Python sinks map to the nearest conceptual §
plus a CWE for precision). All rules are `languages: [python]`.

## Rule catalog

| Rule id | Baseline § | Severity | Enforces / detects |
|---|---|---|---|
| `py-sqli-format` | §2 Database access | ERROR | Dynamic SQL (f-string / `%` / `.format()` / `+`) passed to `.execute()`/`.executemany()`, or assembled into a `sql`/`query`/`stmt`/`statement`-named variable — use parameterized queries. CWE-89. |
| `py-command-injection` | §8a (command-injection) | ERROR | `os.system()`/`os.popen()` on a non-literal, or `subprocess.*(shell=True)` with a non-literal command. Static literals excluded. CWE-78. |
| `py-eval-exec` | §8a | ERROR | `eval()`/`exec()` on a non-literal expression — arbitrary code execution. Static literals excluded. CWE-95. |
| `py-unsafe-deserialization` | §8a (code-injection) | ERROR | `pickle`/`cPickle`/`marshal` `load*()`, or one-arg `yaml.load()` (FullLoader) — arbitrary object construction on load. `safe_load`/`Loader=SafeLoader` not flagged. CWE-502. |
| `py-tls-verify-disabled` | §8 Transport | WARNING | `requests.<verb>(..., verify=False)` or `session.<verb>(..., verify=False)` — disabled TLS verification (MITM). May be intentional for internal CAs — review. CWE-295. |
| `py-hardcoded-secret` | §1 Secrets & config | WARNING | Non-empty string **literal** assigned to a `password`/`passwd`/`secret`/`api_key`/`token`-named var. `os.getenv`/`os.environ`/empty-string RHS excluded. Complements gitleaks. CWE-798. |
| `py-flask-debug` | §9 / §12 | WARNING | `*.run(..., debug=True, ...)` — Flask/Werkzeug debugger is RCE if reachable + leaks tracebacks. CWE-489. |
| `py-weak-hash-password` | §5 (crypto) | WARNING | `hashlib.md5`/`sha1` / `hashlib.new("md5"/"sha1")` — broken for passwords/tokens/signatures (fine for checksums; message says so). CWE-328. |
| `py-assert-security` | §9 | WARNING | `assert ...` used for a runtime check — stripped under `python -O`. Noisy (flags every assert); message says so. CWE-617. |
| `py-jinja-autoescape-off` | §3 Output/XSS | WARNING | `Environment(..., autoescape=False)` / `jinja2.Environment(..., autoescape=False)` — unescaped template output (XSS). CWE-79. |

**Python rule count: 10.**

## Test fixtures

Native semgrep fixtures live in `tests/py_*.py`, same annotation convention (`# ruleid:` /
`# ok:`). Every rule has ≥1 positive and ≥1 negative. All secret values are OBVIOUS FAKES
(`REDACTED_FAKE`). Fixtures are deliberately-insecure test code, each labeled "NOT production code."

| Fixture | Rule exercised |
|---|---|
| `tests/py_sqli.py` | `py-sqli-format` |
| `tests/py_cmdi.py` | `py-command-injection` |
| `tests/py_eval.py` | `py-eval-exec` |
| `tests/py_deser.py` | `py-unsafe-deserialization` |
| `tests/py_tls.py` | `py-tls-verify-disabled` |
| `tests/py_secrets.py` | `py-hardcoded-secret` |
| `tests/py_flask.py` | `py-flask-debug` |
| `tests/py_hash.py` | `py-weak-hash-password` |
| `tests/py_assert.py` | `py-assert-security` |
| `tests/py_jinja.py` | `py-jinja-autoescape-off` |

Run from the `rules/` directory:

```
semgrep --test --config python-baseline.yml tests/
```

> **`semgrep --test` run is PENDING** (semgrep not installed in the authoring environment). Rules and
> fixtures were written by hand and have **not** been executed. Run the command above before relying
> on the ruleset.

### Patterns to double-check on that first run

- **f-string interpolation `f"...{...}..."`** — used in `py-sqli-format` (both the `.execute()` and
  the `$Q = f"..."` branches). This is the single least-certain construct in the file: confirm
  semgrep matches an f-string containing at least one `{ }` interpolation, and that the plain-literal
  `ok` cases (a static string as `.execute()`'s first arg) are correctly NOT matched. If it misparses,
  fall back to a bare `$CUR.execute(f"...")` (accepting the rare constant-f-string false positive).
- **`pattern-not` literal-exclusion idiom** — `py-command-injection` and `py-eval-exec` express
  "non-literal argument" as `pattern: f($X)` **minus** `pattern-not: f("...")`. Confirm `"..."`
  excludes only string literals (so `os.system(cmd)`, `os.system("a"+b)`, `eval(x)` still fire while
  `os.system("ls")`, `eval("2+2")` do not). Deep-expr `<...>` was deliberately avoided here per the
  known statement-position parser bug.
- **Nested `patterns` inside `pattern-either`** — `py-command-injection` nests per-sink `patterns`
  blocks (each a positive + its `pattern-not`s) under one `pattern-either`. Valid semgrep, but verify
  the nesting evaluates per-branch as intended.
- **`subprocess.*(shell=True)` keyword matching** — `subprocess.run($CMD, ..., shell=True, ...)`
  relies on `...` matching the `shell=True` kwarg in any position; confirm, and confirm the
  literal-first-arg `ok` case (`subprocess.run("ls -la", shell=True)`) is excluded by the paired
  `pattern-not`.
- **`yaml.load($X)` single-arg** — depends on `f($X)` matching exactly one argument, so the two-arg
  `yaml.load(raw, Loader=yaml.SafeLoader)` `ok` case does NOT match. Confirm arity behavior.
- **`py-hardcoded-secret` value regex** `^['"].+['"]$` — same idiom as the PHP `hardcoded-secret-define`
  rule: it fires only when the RHS metavariable's source text starts/ends with a quote (a string
  literal), which is also what excludes `os.getenv(...)` and `""`. Confirm semgrep exposes the RHS
  source text with surrounding quotes to `metavariable-regex` (the PHP rule assumes the same).
- **Metavariable method receivers** (`$SESSION.get`, `$APP.run`, `$CUR.execute`, `$Q`) — intentionally
  broad to catch session objects / arbitrary app handles. Expected trade-off: `py-flask-debug` and
  `py-tls-verify-disabled` may match a non-Flask `.run(debug=True)` or a non-requests
  `.get(..., verify=False)`. Both are WARNING and their messages say to confirm the receiver.

### Python items left to the LLM stage (not covered by patterns)

- **Taint provenance for `py-sqli-format`/`py-command-injection`** — the rules flag the dynamic-build
  *shape*, not whether the interpolated value is actually attacker-controlled. A constant f-string or
  a fully-internal command is a possible false positive; whether input is tainted is a dataflow
  question left to review.
- **Weak-hash *purpose* (`py-weak-hash-password`)** — MD5/SHA-1 for a cache key/ETag is fine; for a
  password/token/signature it is a real bug. The pattern cannot tell which; the message asks the
  reviewer to judge.
- **`assert`-for-validation intent (`py-assert-security`)** — flags every `assert`; distinguishing a
  security/validation assert from a test-only invariant needs human judgment.
- **Default-insecure Jinja `Environment()`** — an `Environment()` with *no* `autoescape` argument
  defaults to unescaped in older/base configs, but proving that *absence* across constructors is not a
  single-line pattern; only the explicit `autoescape=False` is flagged.

## JavaScript / TypeScript rule catalog

| Rule id | Baseline § | Severity | Enforces / detects |
|---|---|---|---|
| `innerhtml-string-build` | §3 / §18 | WARNING | Untrusted value string-built into `.innerHTML`/`.outerHTML`/`insertAdjacentHTML`/`document.write`. CWE-79. |
| `js-child-process-exec-concat` | §16 | ERROR | String concatenation into `child_process.exec`/`execSync` — command injection. Use `execFile`/`spawn` with argv. CWE-78. |
| `js-eval-dynamic` | §16 | ERROR | `eval()`/`new Function()` on a non-literal — code injection. Literals excluded. CWE-95. |
| `js-jwt-alg-none` | §16 | ERROR | `algorithms: ['none']` in JWT verification — accepts forged unsigned tokens. CWE-347. |

**JS/TS rule count: 4** (shipped in `web-security-baseline.yml` alongside the PHP rules).

## Java rule catalog (`java-baseline.yml`)

| Rule id | Baseline § | Severity | Enforces / detects |
|---|---|---|---|
| `java-native-deserialization` | §19 | ERROR | `ObjectInputStream.readObject()` — native-deserialization gadget-chain RCE. CWE-502. |
| `java-runtime-exec-concat` | §16 | ERROR | String concatenation into `Runtime.exec()` — command injection. CWE-78. |
| `java-query-concat` | §16 | ERROR | Concatenation into `createQuery`/`createNativeQuery`/`executeQuery` — SQL/HQL/JPQL injection. CWE-89. |
| `java-spel-injection` | §16 | ERROR | `parseExpression()` on a non-constant — SpEL/OGNL server-side expression injection. CWE-917. |
| `java-xml-parser-xxe-review` | §19 | WARNING | XML parser factory constructed (XXE-vulnerable by default) — verify `disallow-doctype-decl`. CWE-611. |

**Java rule count: 5.**

## C# / .NET rule catalog (`csharp-baseline.yml`)

| Rule id | Baseline § | Severity | Enforces / detects |
|---|---|---|---|
| `csharp-insecure-deserializer` | §16 | ERROR | `BinaryFormatter`/`NetDataContractSerializer`/`SoapFormatter`/`LosFormatter`/`ObjectStateFormatter` — RCE gadgets. CWE-502. |
| `csharp-sql-raw` | §16 | ERROR | `FromSqlRaw`/`ExecuteSqlRaw`/`SqlCommand` on a non-literal (interpolated `$"..."`) — SQL injection. Literal+params excluded. CWE-89. |
| `csharp-html-raw` | §16 | ERROR | `Html.Raw()` on a non-constant — defeats Razor auto-encoding (XSS). CWE-79. |
| `csharp-json-typenamehandling` | §19 | ERROR | `TypeNameHandling.All`/`Auto`/`Objects`/`Arrays` — Json.NET polymorphic-typing deserialization RCE. CWE-502. |
| `csharp-process-start-concat` | §16 | ERROR | Concatenation into `Process.Start`/`ProcessStartInfo` — command injection. CWE-78. |
| `csharp-xxe-dtd-parse` | §19 | ERROR | `DtdProcessing.Parse` / `new XmlUrlResolver()` — XXE enabled. CWE-611. |

**C# rule count: 6.**

## Dockerfile rule catalog (`dockerfile-baseline.yml`)

| Rule id | Baseline § | Severity | Enforces / detects |
|---|---|---|---|
| `dockerfile-unpinned-base-latest` | §20 | WARNING | `FROM image:latest` — unpinned base; pin to a `@sha256:` digest. CWE-1357. |
| `dockerfile-secret-in-env-arg` | §20 / §1 | ERROR | Secret-looking value in `ENV`/`ARG` — baked into layer history. CWE-798. |
| `dockerfile-runs-as-root` | §20 | WARNING | `USER root` with no later privilege drop. CWE-250. |

**Dockerfile rule count: 3.**

## Language coverage vs the baseline

Statically ruled today: **PHP, Python, JavaScript/TypeScript, Java, C#, Dockerfile** (+ PowerShell
via PSScriptAnalyzer, + probe/web-root stages). Baseline surfaces still **LLM-review-only** (no
rule): Shell/Bash (shellcheck-class — not yet wired), VBA/Office macros, GitHub Actions YAML
(`pull_request_target` / unpinned `uses:` / `${{ github.event }}`-in-`run:` — fiddly in semgrep
YAML, deferred), and the reasoning-bound classes (CSRF absence, IDOR, eligibility) unchanged.
