#!/usr/bin/env bash
# scan_rules.sh — Stage 2 (rules). Runs the bundled semgrep baseline ruleset
# against a source path. Read-only static analysis. Outputs a human summary to
# stdout and (optionally) JSON for the skill to parse.
#
# Usage: scan_rules.sh <source-path> [--json <out.json>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The rules DIRECTORY — semgrep loads every *.yml in it (PHP + Python + JS rulesets),
# so new language rulesets are picked up automatically.
RULES="$SCRIPT_DIR/../rules"

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

if [ ! -d "$RULES" ]; then
  echo "scan_rules.sh: rules directory not found at $RULES" >&2
  exit 3
fi

run_native() {
  echo "Running semgrep baseline rules against: $SRC"
  echo "Ruleset: $RULES"
  echo
  semgrep --quiet --config "$RULES" "$SRC" || true
  if [ -n "$JSON_OUT" ]; then
    semgrep --quiet --config "$RULES" "$SRC" --json --output "$JSON_OUT" || true
    echo; echo "JSON written to: $JSON_OUT"
  fi
}

run_docker() {
  # Best-effort fallback when native semgrep isn't on PATH (semgrep now installs
  # natively on Windows via pip, so this is rarely needed — see check_deps.sh).
  # NOTE: Docker volume-mount paths can need adjustment on Windows/Git Bash; if
  # mounts fail there, run Censor from WSL or install semgrep inside WSL instead.
  echo "Running semgrep via Docker (semgrep/semgrep) — native semgrep not found."
  local rules_dir src_dir src_arg
  rules_dir="$(cd "$RULES" && pwd)"
  if [ -d "$SRC" ]; then
    src_dir="$(cd "$SRC" && pwd)"; src_arg="/src"
  else
    src_dir="$(cd "$(dirname "$SRC")" && pwd)"; src_arg="/src/$(basename "$SRC")"
  fi
  docker run --rm -v "$rules_dir:/rules:ro" -v "$src_dir:/src:ro" \
    semgrep/semgrep semgrep --quiet --config /rules "$src_arg" || true
  if [ -n "$JSON_OUT" ]; then
    docker run --rm -v "$rules_dir:/rules:ro" -v "$src_dir:/src:ro" \
      semgrep/semgrep semgrep --quiet --config /rules "$src_arg" --json 2>/dev/null > "$JSON_OUT" || true
    echo; echo "JSON written to: $JSON_OUT"
  fi
}

if command -v semgrep >/dev/null 2>&1; then
  run_native
elif command -v docker >/dev/null 2>&1; then
  run_docker
else
  echo "scan_rules.sh: semgrep not installed (and no Docker fallback) — Stage 2 rule scan skipped." >&2
  echo "  install: pipx install semgrep | pip install semgrep | brew install semgrep" >&2
  echo "  (Install: pip install semgrep — runs natively on Windows/Mac/Linux; or use Docker.)" >&2
  exit 3
fi
