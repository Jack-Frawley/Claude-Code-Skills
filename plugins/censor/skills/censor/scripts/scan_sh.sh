#!/usr/bin/env bash
# scan_sh.sh — Stage 2 (shell). Runs shellcheck over shell scripts for the
# SECURITY_BASELINE §16 Shell items (unquoted expansions, eval on input, etc.).
# Read-only. Degrades gracefully if shellcheck isn't installed.
#
# shellcheck is a general linter, so this runs it at --severity=warning to keep
# the output to the higher-signal problems (SC2086 unquoted word-split/glob,
# SC2048/2068 unquoted $@, eval/inject warnings) rather than every style note.
#
# Usage: scan_sh.sh <source-path> [--json <file>]
set -u

SRC=""; JSON_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUT="${2:-}"; shift 2 ;;
    -*) echo "scan_sh.sh: unknown option: $1" >&2; exit 2 ;;
    *) SRC="$1"; shift ;;
  esac
done
[ -n "$SRC" ] || { echo "usage: scan_sh.sh <source-path> [--json <file>]" >&2; exit 2; }
[ -d "$SRC" ] || [ -f "$SRC" ] || { echo "scan_sh.sh: not found: $SRC" >&2; exit 2; }

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "scan_sh.sh: shellcheck not installed — shell scan skipped." >&2
  echo "  install: winget install koalaman.shellcheck  (win) | brew install shellcheck (mac) | apt-get install shellcheck (linux)" >&2
  exit 0
fi

# Collect shell scripts: *.sh/*.bash + files whose shebang is a shell.
mapfile -t files < <(find "$SRC" -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null)
# add extension-less files with a shell shebang
while IFS= read -r f; do
  head -c 40 "$f" 2>/dev/null | grep -qE '^#!.*/(ba)?sh\b' && files+=("$f")
done < <(find "$SRC" -type f ! -name '*.*' 2>/dev/null)

if [ "${#files[@]}" -eq 0 ]; then
  echo "scan_sh.sh: no shell scripts under $SRC — nothing to scan."
  exit 0
fi

echo "Running shellcheck (severity>=warning) against ${#files[@]} shell script(s) under: $SRC"

if [ -n "$JSON_OUT" ]; then
  shellcheck --severity=warning --format=json1 "${files[@]}" > "$JSON_OUT" 2>/dev/null || true
  n=$(python -c "import json,sys; d=json.load(open(r'$JSON_OUT')); print(len(d.get('comments',[])))" 2>/dev/null || echo "?")
  echo "  $n shellcheck finding(s) (severity>=warning). JSON: $JSON_OUT"
else
  shellcheck --severity=warning "${files[@]}" || true
fi
exit 0
