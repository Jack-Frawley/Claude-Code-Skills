#!/usr/bin/env bash
# run_tests.sh — Censor deterministic-core test harness.
# Validates the three deterministic legs. Skips (does not fail) a leg whose tool
# is absent, so partial runs are still useful. Exit non-zero if any RUN leg fails.
#
# The gitleaks fixture is GENERATED at runtime in a temp dir and deleted, so no
# secret-shaped content is ever committed to the repo.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$HERE/../plugins/censor/skills/censor"
RULES="$SKILL/rules"
SCRIPTS="$SKILL/scripts"

pass=0; fail=0; skip=0
ok()   { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
skp()  { printf '  [SKIP] %s\n' "$1"; skip=$((skip+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

echo "Censor test harness"
echo "==================="

# 1) semgrep rule tests (native positive/negative fixtures under rules/tests/)
echo "1) semgrep --test (ruleset vs fixtures)"
if ! have semgrep; then
  skp "semgrep not installed"
elif [ ! -d "$RULES" ]; then
  bad "rules dir missing: $RULES"
else
  if semgrep --test --config "$RULES" "$RULES/tests" >/tmp/censor_semgrep_test.out 2>&1; then
    ok "semgrep rule tests"
  else
    bad "semgrep rule tests (see /tmp/censor_semgrep_test.out)"
    tail -n 20 /tmp/censor_semgrep_test.out 2>/dev/null | sed 's/^/      /'
  fi
fi

# 2) gitleaks detects a RUNTIME-GENERATED fixture (nothing secret-shaped is committed)
echo "2) gitleaks (generated fixture)"
if ! have gitleaks; then
  skp "gitleaks not installed"
else
  TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/censor_test_$$")"
  mkdir -p "$TMPD"
  # obvious fake — a structurally-invalid key block, generated here, never committed
  {
    printf '%s\n' "-----BEGIN RSA PRIVATE KEY-----"
    printf '%s\n' "MIIFAKEFAKEfakeFAKEnotarealkeyjustatestfixture000000000000000000"
    printf '%s\n' "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    printf '%s\n' "-----END RSA PRIVATE KEY-----"
  } > "$TMPD/generated_fixture.txt"
  gitleaks detect --source "$TMPD" --no-git --redact --report-format json \
    --report-path "$TMPD/report.json" --exit-code 0 >/dev/null 2>&1
  n=$(grep -c '"RuleID"' "$TMPD/report.json" 2>/dev/null || echo 0)
  rm -rf "$TMPD"
  if [ "${n:-0}" -ge 1 ]; then
    ok "gitleaks found $n secret(s) in generated fixture"
  else
    bad "gitleaks found no secrets in generated fixture (expected >=1)"
  fi
fi

# 3) probe.sh self-test (no network)
echo "3) probe.sh --selftest"
if [ ! -f "$SCRIPTS/probe.sh" ]; then
  bad "probe.sh missing"
elif bash "$SCRIPTS/probe.sh" --selftest >/dev/null 2>&1; then
  ok "probe.sh selftest"
else
  bad "probe.sh selftest"
fi

# 4) scripts parse cleanly
echo "4) bash -n on all scripts"
for s in check_deps.sh probe.sh scan_rules.sh scan_secrets.sh; do
  if [ -f "$SCRIPTS/$s" ]; then
    if bash -n "$SCRIPTS/$s" 2>/dev/null; then ok "parse $s"; else bad "parse $s"; fi
  else
    bad "missing $s"
  fi
done

echo
echo "Summary: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
