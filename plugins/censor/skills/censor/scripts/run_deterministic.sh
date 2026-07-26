#!/usr/bin/env bash
# run_deterministic.sh — run ALL of Censor's deterministic (no-LLM) stages against
# a target in one shot and collect the results as JSON artifacts. Read-only; never
# executes or modifies the target. The skill's Stage-3 LLM review layers on top of
# these outputs.
#
# Usage:
#   run_deterministic.sh --source <path> [--url <base-url>] [--out-dir <dir>]
#   run_deterministic.sh --url <base-url> [--out-dir <dir>]         # black-box only
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="$SCRIPT_DIR/../rules"
SRC=""; URL=""; OUT="./censor-out"
SARIF=0            # --sarif: also emit SARIF (GitHub code-scanning / VS Code)
FAIL_ON=""         # --fail-on error|high : exit non-zero if a finding at/above it (CI gate)

WEBROOT="${WEBROOT:-}"

# pwsh is a Windows program under Git Bash; convert MSYS paths to Windows paths for it.
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --source)  SRC="${2:-}"; shift 2 ;;
    --url)     URL="${2:-}"; shift 2 ;;
    --webroot) WEBROOT="${2:-}"; shift 2 ;;
    --out-dir) OUT="${2:-}"; shift 2 ;;
    --sarif)   SARIF=1; shift ;;
    --fail-on) FAIL_ON="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
    -h|--help) echo "usage: run_deterministic.sh [--source <path>] [--url <base-url>] [--webroot <document-root>] [--out-dir <dir>] [--sarif] [--fail-on error|high]"; exit 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SRC" ] && [ -z "$URL" ] && [ -z "${WEBROOT:-}" ]; then
  echo "run_deterministic.sh: need --source and/or --url and/or --webroot" >&2
  exit 2
fi
mkdir -p "$OUT"

echo "================================================================"
echo " Censor — deterministic pipeline (read-only)"
echo " source: ${SRC:-<none>}   url: ${URL:-<none>}
 webroot: ${WEBROOT:-<none>}   out: $OUT"
echo "================================================================"
echo

echo "--- dependencies ---"
bash "$SCRIPT_DIR/check_deps.sh" | tee "$OUT/deps.txt" | grep -E '^\s{2}\[|^AVAILABLE|^OS:' || true
echo

if [ -n "$URL" ]; then
  echo "--- Stage 1: probe ($URL) ---"
  bash "$SCRIPT_DIR/probe.sh" "$URL" --out "$OUT/probe.json" || true
  echo
fi

if [ -n "${WEBROOT:-}" ]; then
  echo "--- Stage 1.5: web-root inventory ($WEBROOT) ---"
  bash "$SCRIPT_DIR/scan_webroot.sh" "$WEBROOT" --out "$OUT/webroot.json" || true
  echo
fi

if [ -n "$SRC" ]; then
  echo "--- Stage 2: baseline rules (semgrep) ---"
  bash "$SCRIPT_DIR/scan_rules.sh" "$SRC" --json "$OUT/rules.json" || true
  echo
  echo "--- Stage 2: secrets (gitleaks) ---"
  bash "$SCRIPT_DIR/scan_secrets.sh" "$SRC" --json "$OUT/secrets.json" || true
  echo

  # SARIF outputs — ingestible by GitHub code scanning and the VS Code SARIF
  # viewer. Native tools only (Docker/other fallbacks keep the JSON path).
  if [ "$SARIF" = "1" ]; then
    if command -v semgrep >/dev/null 2>&1; then
      echo "--- SARIF: semgrep -> $OUT/semgrep.sarif ---"
      semgrep --quiet --config "$RULES_DIR" --sarif --output "$OUT/semgrep.sarif" "$SRC" 2>/dev/null || true
    fi
    if command -v gitleaks >/dev/null 2>&1; then
      echo "--- SARIF: gitleaks -> $OUT/gitleaks.sarif ---"
      gitleaks detect --source "$SRC" --no-git --redact \
        --report-format sarif --report-path "$OUT/gitleaks.sarif" --exit-code 0 2>/dev/null || true
    fi
    echo
  fi
  # PowerShell scan only when the source actually contains PS files and pwsh exists.
  if command -v pwsh >/dev/null 2>&1 \
     && find "$SRC" -type f \( -name '*.ps1' -o -name '*.psm1' -o -name '*.psd1' \) -print -quit 2>/dev/null | grep -q .; then
    echo "--- Stage 2: PowerShell (PSScriptAnalyzer) ---"
    pwsh -NoProfile -File "$(winpath "$SCRIPT_DIR/scan_ps.ps1")" -Path "$(winpath "$SRC")" -Json "$(winpath "$OUT/ps.json")" || true
    echo
  fi
  # Shell scan only when the source contains shell scripts and shellcheck exists.
  if command -v shellcheck >/dev/null 2>&1 \
     && find "$SRC" -type f \( -name '*.sh' -o -name '*.bash' \) -print -quit 2>/dev/null | grep -q .; then
    echo "--- Stage 2: Shell (shellcheck) ---"
    bash "$SCRIPT_DIR/scan_sh.sh" "$SRC" --json "$OUT/sh.json" || true
    echo
  fi
fi

echo "================================================================"
echo " Deterministic stages complete. Artifacts in: $OUT/"
echo "   probe.json  rules.json  secrets.json  ps.json  webroot.json  deps.txt"
[ "$SARIF" = "1" ] && echo "   semgrep.sarif  gitleaks.sarif   (upload to GitHub code scanning)"
echo " Next (skill Stage 3): read these + the flagged files for the LLM review,"
echo " apply any .censorignore suppressions during synthesis, write the advisory."
echo "================================================================"

# ── CI gate ───────────────────────────────────────────────────────────────
# --fail-on error : fail if a semgrep ERROR, any gitleaks secret, a web-root
#                   CRITICAL, or a probe HIGH exists.
# --fail-on high  : the above PLUS semgrep WARNING and web-root HIGH.
# This is a WHOLE-scan gate. A "new findings only" diff against a stored baseline
# is a planned follow-up (snapshot the JSON, compare on next run).
if [ -n "$FAIL_ON" ]; then
  gate=$(python - "$OUT" "$FAIL_ON" <<'PY' 2>/dev/null || echo "?"
import json, os, sys
outdir, level = sys.argv[1], sys.argv[2]
def load(p):
    p = os.path.join(outdir, p)
    if os.path.exists(p) and os.path.getsize(p) > 0:
        try: return json.load(open(p, encoding="utf-8"))
        except Exception: return None
    return None
n = 0
rules = load("rules.json") or {}
for r in rules.get("results", []):
    sev = (r.get("extra", {}) or {}).get("severity", r.get("severity", "")).upper()
    if sev == "ERROR" or (level == "high" and sev in ("ERROR", "WARNING")):
        n += 1
sec = load("secrets.json")            # any redacted secret counts
if isinstance(sec, list): n += len(sec)
def sev_findings(doc, sevs):
    return sum(1 for f in (doc or {}).get("findings", []) if f.get("severity", "").upper() in sevs)
wr = load("webroot.json")
n += sev_findings(wr, {"CRITICAL"} | ({"HIGH"} if level == "high" else set()))
pr = load("probe.json")
n += sev_findings(pr, {"HIGH"})
print(n)
PY
)
  echo
  if [ "$gate" = "0" ]; then
    echo "CI gate (--fail-on $FAIL_ON): PASS — no findings at/above '$FAIL_ON'."
  else
    echo "CI gate (--fail-on $FAIL_ON): FAIL — $gate finding(s) at/above '$FAIL_ON'." >&2
    exit 3
  fi
fi
