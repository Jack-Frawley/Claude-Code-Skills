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
SRC=""; URL=""; OUT="./censor-out"

# pwsh is a Windows program under Git Bash; convert MSYS paths to Windows paths for it.
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --source)  SRC="${2:-}"; shift 2 ;;
    --url)     URL="${2:-}"; shift 2 ;;
    --out-dir) OUT="${2:-}"; shift 2 ;;
    -h|--help) echo "usage: run_deterministic.sh --source <path> [--url <base-url>] [--out-dir <dir>]"; exit 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SRC" ] && [ -z "$URL" ]; then
  echo "run_deterministic.sh: need --source and/or --url" >&2
  exit 2
fi
mkdir -p "$OUT"

echo "================================================================"
echo " Censor — deterministic pipeline (read-only)"
echo " source: ${SRC:-<none>}   url: ${URL:-<none>}   out: $OUT"
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

if [ -n "$SRC" ]; then
  echo "--- Stage 2: baseline rules (semgrep) ---"
  bash "$SCRIPT_DIR/scan_rules.sh" "$SRC" --json "$OUT/rules.json" || true
  echo
  echo "--- Stage 2: secrets (gitleaks) ---"
  bash "$SCRIPT_DIR/scan_secrets.sh" "$SRC" --json "$OUT/secrets.json" || true
  echo
  # PowerShell scan only when the source actually contains PS files and pwsh exists.
  if command -v pwsh >/dev/null 2>&1 \
     && find "$SRC" -type f \( -name '*.ps1' -o -name '*.psm1' -o -name '*.psd1' \) -print -quit 2>/dev/null | grep -q .; then
    echo "--- Stage 2: PowerShell (PSScriptAnalyzer) ---"
    pwsh -NoProfile -File "$(winpath "$SCRIPT_DIR/scan_ps.ps1")" -Path "$(winpath "$SRC")" -Json "$(winpath "$OUT/ps.json")" || true
    echo
  fi
fi

echo "================================================================"
echo " Deterministic stages complete. Artifacts in: $OUT/"
echo "   probe.json  rules.json  secrets.json  ps.json  deps.txt"
echo " Next (skill Stage 3): read these + the flagged files for the LLM review,"
echo " apply any .censorignore suppressions during synthesis, write the advisory."
echo "================================================================"
