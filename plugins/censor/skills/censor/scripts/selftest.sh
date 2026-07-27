#!/usr/bin/env bash
# selftest.sh — prove Censor actually works IN THIS ENVIRONMENT.
#
# Runs the REAL scan path (not `semgrep --test`, which dodged a config-load bug
# that silently returned 0 findings on real code) against a bundled known-BAD
# corpus and asserts the expected rules fire, then against the known-GOOD corpus
# and asserts silence. A recipient runs this once after install to confirm the
# tool is functioning — CI-green on someone else's repo does not guarantee it.
#
# Exit: 0 all checks pass; 1 a check failed; 2 a required tool is missing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES="$HERE/../rules"
KB="$RULES/known_bad"
GOOD="$RULES/corpus"
pass=0; fail=0
ok(){ printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

echo "Censor selftest — verifying the scan pipeline in this environment"
echo "=================================================================="

if ! command -v semgrep >/dev/null 2>&1; then
  echo "  semgrep not found — Stage 2 cannot run. Install: pip install semgrep" >&2
  echo "  (probe + web-root + gitleaks + LLM review still work without it.)" >&2
  exit 2
fi

# Build config from TOP-LEVEL rule files only (never --config the dir: it would
# recurse into tests/ + corpus/ + known_bad/ .yml fixtures and invalidate the load).
CFG=(); for f in "$RULES"/*.yml; do [ -f "$f" ] && CFG+=(--config "$f"); done
echo "  loaded ${#CFG[@]} rule files"

# Rule-ids the known-bad corpus MUST surface (one representative per language +
# the taint path). If the config fails to load, NONE appear -> every check fails.
EXPECT="phpinfo-call cookie-as-identity echo-request-unescaped php-taint-command-exec \
py-hardcoded-secret py-sqli-format py-odbc-trust-server-cert js-eval-dynamic js-jwt-alg-none \
java-native-deserialization csharp-insecure-deserializer dockerfile-unpinned-base-latest \
dockerfile-secret-in-env-arg actions-pull-request-target actions-untrusted-input-in-run"

echo "-- Stage 2 fires on known-bad code --"
got=$(semgrep --quiet "${CFG[@]}" "$KB" --json 2>/dev/null \
      | python -c "import json,sys; print(' '.join(sorted({r['check_id'].split('.')[-1] for r in json.load(sys.stdin).get('results',[])})))" 2>/dev/null)
if [ -z "$got" ]; then
  bad "known-bad scan produced NO findings — the ruleset failed to LOAD (this is the silent-false-clean failure mode)"
else
  miss=""
  for r in $EXPECT; do case " $got " in *" $r "*) : ;; *) miss="$miss $r" ;; esac; done
  if [ -z "$miss" ]; then
    ok "all ${EXPECT// /,} representative rules fired ($(echo "$got" | wc -w) distinct rules total)"
  else
    bad "expected rule(s) did NOT fire:$miss"
  fi
fi

echo "-- Stage 2 stays SILENT on known-good code --"
if [ -d "$GOOD" ]; then
  n=$(semgrep --quiet "${CFG[@]}" "$GOOD" --json 2>/dev/null \
      | python -c "import json,sys; print(len(json.load(sys.stdin).get('results',[])))" 2>/dev/null)
  [ "${n:-1}" = "0" ] && ok "FP-corpus clean (0 findings)" || bad "FP-corpus: $n finding(s) on known-good code"
fi

echo "-- secret scan --"
if command -v gitleaks >/dev/null 2>&1; then
  # a plainly-fake secret gitleaks catches (the AWS "AKIAIOSFODNN7EXAMPLE" key is
  # allowlisted by gitleaks, so it can't be used as a positive control).
  tmp=$(mktemp -d); printf 'stripe_key = "sk_live_%s"\n' "9f8e7d6c5b4a3210deadbeefcafef00d" > "$tmp/s.txt"
  gitleaks detect --source "$tmp" --no-git --redact --report-format json --report-path "$tmp/r.json" --exit-code 0 >/dev/null 2>&1 || true
  # count with grep (a bash/MSYS tool) — Windows python cannot resolve a Git-Bash
  # /tmp/... path, so read the report with a tool that shares the shell's view of it.
  gl=$(grep -c '"RuleID"' "$tmp/r.json" 2>/dev/null || echo 0)
  [ "${gl:-0}" -ge 1 ] 2>/dev/null && ok "gitleaks fires on a planted secret" || bad "gitleaks did not flag a planted secret"
  rm -rf "$tmp"
else
  printf '  [SKIP] gitleaks not installed (winget install Gitleaks.Gitleaks)\n'
fi

echo "-- other stages load --"
bash "$HERE/probe.sh" --selftest >/dev/null 2>&1 && ok "probe.sh" || bad "probe.sh selftest"
bash "$HERE/scan_webroot.sh" --selftest >/dev/null 2>&1 && ok "scan_webroot.sh" || bad "scan_webroot.sh selftest"

echo "=================================================================="
echo "selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && { echo "Censor is functioning in this environment."; exit 0; } \
                  || { echo "Censor is NOT fully functioning — see failures above." >&2; exit 1; }
