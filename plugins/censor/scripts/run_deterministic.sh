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
BASELINE=""        # --baseline <file> : gate on findings NEW since this snapshot only
UPDATE_BASELINE=0  # --update-baseline : (re)write the snapshot from this run, accept current state

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
    --baseline) BASELINE="${2:-}"; shift 2 ;;
    --update-baseline) UPDATE_BASELINE=1; shift ;;
    -h|--help) echo "usage: run_deterministic.sh [--source <path>] [--url <base-url>] [--webroot <document-root>] [--out-dir <dir>] [--sarif] [--fail-on error|high] [--baseline <file>] [--update-baseline]"; exit 2 ;;
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
      # top-level rule files only — never --config the dir (it recurses into the
      # tests/ + corpus/ .yml fixtures and returns an empty/invalid result).
      scfg=(); for _f in "$RULES_DIR"/*.yml; do [ -f "$_f" ] && scfg+=(--config "$_f"); done
      semgrep --quiet "${scfg[@]}" --sarif --output "$OUT/semgrep.sarif" "$SRC" 2>/dev/null || true
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

# ── CI gate + baseline diff ────────────────────────────────────────────────
# --fail-on error : fail on a semgrep ERROR / any secret / web-root CRITICAL /
#                   probe HIGH.  --fail-on high : + semgrep WARNING / web-root HIGH.
# --baseline <f>  : gate only on findings NEW since snapshot <f> (each finding has
#                   a stable fingerprint, so line drift does not resurrect it).
#                   Lets a team turn the gate on over an existing backlog: accept
#                   the backlog once (--update-baseline), then only new issues fail.
# --update-baseline : (re)write <f> from this run and accept the current state.
if [ -n "$FAIL_ON" ] || [ -n "$BASELINE" ] || [ "$UPDATE_BASELINE" = "1" ]; then
  echo
  # One python pass: build a per-finding fingerprint, optionally write/diff the
  # baseline, print a human line, and emit "GATE <n>" for the shell to act on.
  # NOTE: semgrep CE's extra.fingerprint is the placeholder "requires login" (a
  # gated platform feature) — useless for identity — so fingerprints are built
  # from rule:relpath:line. Line-based means editing a file can make baselined
  # findings look new; that errs toward FAILING (safe for a security gate), and
  # you re-baseline after intentional edits.
  gate_out=$(python - "$OUT" "${FAIL_ON:-none}" "${BASELINE:-}" "$UPDATE_BASELINE" <<'PY'
import json, os, sys
outdir, level, baseline, do_update = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
def load(p):
    p = os.path.join(outdir, p)
    if os.path.exists(p) and os.path.getsize(p) > 0:
        try: return json.load(open(p, encoding="utf-8"))
        except Exception: return None
    return None
def rel(p):
    p = (p or "").replace("\\", "/")
    return p.rsplit("/", 3)[-1] if p.count("/") > 3 else p
findings = []  # (fingerprint, is_serious)
for r in (load("rules.json") or {}).get("results", []):
    sev = (r.get("extra", {}) or {}).get("severity", r.get("severity", "")).upper()
    rid = r.get("check_id", "").split(".")[-1]
    fp = f"semgrep:{rid}:{rel(r.get('path'))}:{r.get('start',{}).get('line')}"
    findings.append((fp, sev == "ERROR" or (level == "high" and sev == "WARNING")))
sec = load("secrets.json")
if isinstance(sec, list):
    for s in sec:
        findings.append((f"secret:{s.get('RuleID')}:{rel(s.get('File'))}:{s.get('StartLine')}", True))
for name, sevs in (("webroot.json", {"CRITICAL"} | ({"HIGH"} if level == "high" else set())),
                   ("probe.json", {"HIGH"})):
    for f in (load(name) or {}).get("findings", []):
        findings.append((f"{name}:{f.get('check')}:{f.get('path','')}",
                         f.get("severity", "").upper() in sevs))
cur = {fp for fp, _ in findings}
serious = {fp for fp, s in findings if s}
base = set()
if baseline and os.path.exists(baseline):
    try: base = set(json.load(open(baseline, encoding="utf-8")).get("fingerprints", []))
    except Exception: pass
have_base = bool(baseline and os.path.exists(baseline))
new_serious = (serious - base) if have_base else serious
if do_update and baseline:
    json.dump({"fingerprints": sorted(cur)}, open(baseline, "w", encoding="utf-8"), indent=0)
    print(f"MSG baseline written: {len(cur)} finding(s) accepted -> {baseline}")
    print("GATE -1")   # -1 = do not gate (snapshot run)
elif have_base:
    print(f"MSG {len(serious)} serious finding(s): {len(serious & base)} baselined, {len(new_serious)} new")
    print(f"GATE {len(new_serious)}")
else:
    print(f"GATE {len(serious)}")
PY
)
  echo "$gate_out" | grep '^MSG ' | sed 's/^MSG /  /'
  gate=$(echo "$gate_out" | sed -n 's/^GATE //p')
  if [ "$gate" = "-1" ]; then
    :  # baseline snapshot run — not a gate
  elif [ -n "$FAIL_ON" ]; then
    if [ "${gate:-0}" = "0" ]; then
      echo "CI gate (--fail-on $FAIL_ON${BASELINE:+, new-since-baseline}): PASS"
    else
      echo "CI gate (--fail-on $FAIL_ON${BASELINE:+, new-since-baseline}): FAIL — ${gate} finding(s) at/above '$FAIL_ON'." >&2
      exit 3
    fi
  fi
fi
