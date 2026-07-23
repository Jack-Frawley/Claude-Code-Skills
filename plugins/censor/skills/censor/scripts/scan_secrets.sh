#!/usr/bin/env bash
# scan_secrets.sh — Stage 2 (secrets). Runs gitleaks against a source path to
# find committed / in-tree secrets. Read-only. IMPORTANT: gitleaks reports the
# rule + location; this wrapper prints locations only. Never echo secret values
# downstream — refer to them by file:line when writing the advisory.
#
# Usage: scan_secrets.sh <source-path> [--json <out.json>]
set -u

SRC="${1:-}"
if [ -z "$SRC" ] || [ "$SRC" = "-h" ] || [ "$SRC" = "--help" ]; then
  echo "usage: scan_secrets.sh <source-path> [--json <out.json>]" >&2
  exit 2
fi
if [ ! -e "$SRC" ]; then
  echo "scan_secrets.sh: path not found: $SRC" >&2
  exit 2
fi

JSON_OUT=""
if [ "${2:-}" = "--json" ]; then JSON_OUT="${3:-}"; fi

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "scan_secrets.sh: gitleaks not installed — secret scan skipped." >&2
  echo "  install: https://github.com/gitleaks/gitleaks/releases  (or)  brew install gitleaks" >&2
  echo "  (the semgrep 'hardcoded-secret-define' rule + the LLM review partially compensate)" >&2
  exit 3
fi

echo "Running gitleaks against: $SRC"
echo "(reports locations only; rotate anything it flags — never paste values into the advisory)"
echo

# --no-git so it scans a plain directory (not just git history). Non-fatal on findings.
if [ -n "$JSON_OUT" ]; then
  gitleaks detect --source "$SRC" --no-git --redact --report-format json --report-path "$JSON_OUT" --exit-code 0 || true
  echo
  echo "JSON written to: $JSON_OUT"
else
  gitleaks detect --source "$SRC" --no-git --redact --exit-code 0 || true
fi
