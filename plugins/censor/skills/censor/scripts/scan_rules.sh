#!/usr/bin/env bash
# scan_rules.sh — Stage 2 (rules). Runs the bundled semgrep baseline ruleset
# against a source path. Read-only static analysis. Outputs a human summary to
# stdout and (optionally) JSON for the skill to parse.
#
# Usage: scan_rules.sh <source-path> [--json <out.json>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES="$SCRIPT_DIR/../rules/web-security-baseline.yml"

SRC="${1:-}"
if [ -z "$SRC" ] || [ "$SRC" = "-h" ] || [ "$SRC" = "--help" ]; then
  echo "usage: scan_rules.sh <source-path> [--json <out.json>]" >&2
  exit 2
fi
if [ ! -e "$SRC" ]; then
  echo "scan_rules.sh: path not found: $SRC" >&2
  exit 2
fi

JSON_OUT=""
if [ "${2:-}" = "--json" ]; then JSON_OUT="${3:-}"; fi

if ! command -v semgrep >/dev/null 2>&1; then
  echo "scan_rules.sh: semgrep not installed — Stage 2 rule scan skipped." >&2
  echo "  install: pipx install semgrep  (or)  pip install semgrep  (or)  brew install semgrep" >&2
  exit 3
fi
if [ ! -f "$RULES" ]; then
  echo "scan_rules.sh: ruleset not found at $RULES" >&2
  exit 3
fi

echo "Running semgrep baseline rules against: $SRC"
echo "Ruleset: $RULES"
echo

# Human-readable pass (semgrep's own formatting), non-fatal on findings.
semgrep --quiet --config "$RULES" "$SRC" || true

# Optional machine-readable pass for the skill.
if [ -n "$JSON_OUT" ]; then
  semgrep --quiet --config "$RULES" "$SRC" --json --output "$JSON_OUT" || true
  echo
  echo "JSON written to: $JSON_OUT"
fi
