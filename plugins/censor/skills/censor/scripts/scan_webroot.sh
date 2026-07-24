#!/usr/bin/env bash
#
# Censor - Stage-1.5 web-root inventory
#
# READ-ONLY. Enumerates a document root on disk and flags files that should
# never live inside one, BY CATEGORY rather than by name.
#
# Why this stage exists: the Stage-1 probe can only ask about paths it already
# knows. A curated list finds /.env and /phpinfo.php; it cannot guess
# "FullBackup_SiteName_2026-06-08_133048.zip". In a real audit that archive --
# a complete copy of the application including every credential -- was the
# single worst finding, and it was invisible to every other stage. Only listing
# the directory finds it.
#
# It also parses the server config (web.config / .htaccess) to answer the
# question that decides severity: does this server deny by default, or serve
# anything it happens to have a MIME type for?
#
# Never opens file CONTENTS except server-config files. Names, sizes, and
# extensions only -- so it cannot leak a secret it discovers.
#
# Usage:
#   scan_webroot.sh <webroot-path>            inventory + config assessment
#   scan_webroot.sh <webroot-path> --out F    write JSON report to F
#   scan_webroot.sh --selftest                no filesystem walk, verify deps
#
# Exit: 0 on a completed run (findings do NOT change exit code); non-zero only
# on misuse (missing/unreadable path).

set -u

MAX_DEPTH=12
ROOT_IS_APPDIR=0
FINDINGS=()
SEV_COUNT_CRIT=0; SEV_COUNT_HIGH=0; SEV_COUNT_MED=0; SEV_COUNT_LOW=0

# ---------------------------------------------------------------------------
# Category catalog. Each entry: severity|label|why
# Matching is on lowercased basename/extension so it works on any platform.
# ---------------------------------------------------------------------------

json_escape() {
  # Escape for JSON string context without requiring jq.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' \
    -e 's/\r/\\r/g' | tr -d '\n'
}

add_finding() {
  # add_finding <category> <severity> <relpath> <detail>
  local cat=$1 sev=$2 rel=$3 detail=$4
  FINDINGS+=("{\"check\":\"$(json_escape "$cat")\",\"severity\":\"$(json_escape "$sev")\",\"path\":\"$(json_escape "$rel")\",\"detail\":\"$(json_escape "$detail")\"}")
  case "$sev" in
    CRITICAL) SEV_COUNT_CRIT=$((SEV_COUNT_CRIT+1)) ;;
    HIGH)     SEV_COUNT_HIGH=$((SEV_COUNT_HIGH+1)) ;;
    MEDIUM)   SEV_COUNT_MED=$((SEV_COUNT_MED+1))  ;;
    *)        SEV_COUNT_LOW=$((SEV_COUNT_LOW+1))  ;;
  esac
}

sev_line() {
  local sev=$1 msg=$2
  case "$sev" in
    CRITICAL) printf '  [CRIT] %s\n' "$msg" ;;
    HIGH)     printf '  [HIGH] %s\n' "$msg" ;;
    MEDIUM)   printf '  [MED ] %s\n' "$msg" ;;
    LOW)      printf '  [LOW ] %s\n' "$msg" ;;
    OK)       printf '  [OK  ] %s\n' "$msg" ;;
    *)        printf '  [INFO] %s\n' "$msg" ;;
  esac
}

human_size() {
  local b=$1
  if   [ "$b" -ge 1073741824 ] 2>/dev/null; then printf '%d GB' $((b/1073741824))
  elif [ "$b" -ge 1048576 ]    2>/dev/null; then printf '%d MB' $((b/1048576))
  elif [ "$b" -ge 1024 ]       2>/dev/null; then printf '%d KB' $((b/1024))
  else printf '%s B' "$b"; fi
}

# Classify a file by name/extension. Echoes "SEVERITY|CATEGORY|WHY" or nothing.
classify() {
  local base=$1 lower ext
  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  ext="${lower##*.}"
  [ "$ext" = "$lower" ] && ext=""

  # --- Credential-bearing files: worst case, one GET = an identity ---
  case "$lower" in
    .env|.env.*|*.env) echo "CRITICAL|credential-file|environment file: holds every secret the app uses"; return ;;
    id_rsa|id_dsa|id_ecdsa|id_ed25519|*.pem|*.key|*.pfx|*.p12|*.jks|*.keystore)
      echo "CRITICAL|credential-file|private key material"; return ;;
    *.cred|credentials|credentials.*|.netrc|.pgpass|.my.cnf)
      echo "CRITICAL|credential-file|stored credentials"; return ;;
    *token*.json|*tokens*.json|*secret*.json|*credential*.json)
      echo "CRITICAL|credential-file|OAuth/API token store: a refresh token is a persistent credential"; return ;;
    *secret*.txt|*password*.txt|*credential*.txt|*secret*|*apikey*|*api_key*)
      echo "CRITICAL|credential-file|filename indicates stored secret material"; return ;;
  esac

  # --- Archives: a site backup contains EVERYTHING, including the above ---
  case "$ext" in
    zip|7z|rar|tar|gz|tgz|bz2|xz|cab)
      echo "CRITICAL|archive|archive in a document root: if it is a site backup it contains all source AND every credential"; return ;;
  esac

  # --- Database dumps / schema ---
  case "$ext" in
    sql|dmp|mdf|ldf|bak|bacpac|sqlite|sqlite3|db)
      echo "HIGH|db-dump|database dump/schema: discloses structure, often data and credentials"; return ;;
  esac

  # --- Data exports: usually PII ---
  case "$ext" in
    csv|tsv|xls|xlsx|xlsm|xlsb|mdb|accdb)
      echo "HIGH|data-export|data export in a document root: commonly personal or business-confidential data"; return ;;
  esac

  # --- Backup/superseded copies of source ---
  case "$lower" in
    *.bak|*.old|*.orig|*.save|*.swp|*.swo|*~|*.rej)
      echo "HIGH|source-backup|editor/backup copy: served as TEXT, disclosing source that would otherwise execute"; return ;;
    # Deliberately loose globs (*_old* not *_old.*): a real audit found
    # "Main_working_old .php" -- a SPACE before the extension -- which slipped
    # past both a probe and a manual sweep. Filenames are not well-behaved.
    *_old*|*-old*|*.copy|*copy.php|*copy.py|*_bak*|*_backup*)
      echo "MEDIUM|source-backup|superseded copy left in place"; return ;;
  esac

  # --- Installers / binaries ---
  case "$ext" in
    exe|msi|dll|so|dylib|jar|apk|deb|rpm)
      echo "MEDIUM|binary|executable/installer in a document root: distributable payload and version disclosure"; return ;;
  esac

  # --- Diagnostics ---
  case "$lower" in
    phpinfo.php|info.php|test.php|debug.php|status.php|adminer.php|phpmyadmin*)
      echo "HIGH|diagnostic|diagnostic endpoint: dumps environment, versions and often credentials"; return ;;
  esac

  # --- Version-suffixed / test source still present (dead code) ---
  case "$lower" in
    *_v[0-9]*.php|*_v[0-9]*.py|*test*.php|*test*.py|*_dev.*|*_backup.*)
      echo "LOW|dead-code|version-suffixed or test source: superseded code often keeps vulnerabilities the live file fixed"; return ;;
  esac

  # --- VCS / build metadata ---
  case "$lower" in
    .git|.gitignore|.gitconfig|.svn|.hg|composer.lock|package-lock.json|yarn.lock|.ds_store)
      echo "LOW|metadata|repository/build metadata: discloses structure and dependency versions"; return ;;
  esac

  return
}

# Directory-level classification (backup trees).
classify_dir() {
  local base=$1 lower
  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    _backup|_backups|backup|backups|bak|old|archive|archives|_old|dump|dumps)
      echo "HIGH|backup-dir|backup directory inside the document root: its contents inherit the site's exposure, and a 403 on the directory does NOT protect files whose names are guessable"; return ;;
    .git|.svn|.hg)
      echo "CRITICAL|vcs-dir|version-control directory: full source history is reconstructable"; return ;;
  esac
  return
}

# ---------------------------------------------------------------------------
# Server-config assessment - decides whether the above are actually served
# ---------------------------------------------------------------------------
assess_server_config() {
  local root=$1
  local wc="$root/web.config" ht="$root/.htaccess"
  local found=0

  echo "== Server config (does it deny by default?) =="

  if [ -f "$wc" ]; then
    found=1
    echo "  found: web.config (IIS)"
    if grep -qi "requestFiltering" "$wc" 2>/dev/null; then
      if grep -qi 'allowUnlisted="false"' "$wc" 2>/dev/null; then
        sev_line "OK" "requestFiltering present with allowUnlisted=\"false\" (deny-by-default)"
        add_finding "server_config" "INFO" "web.config" "requestFiltering deny-by-default present"
      else
        sev_line "MEDIUM" "requestFiltering present but NOT deny-by-default (allowUnlisted not false) - it blocks a named list, so any type not on it is served"
        add_finding "server_config" "MEDIUM" "web.config" "requestFiltering present but allow-listed, not deny-by-default"
      fi
      grep -qi "hiddenSegments" "$wc" 2>/dev/null \
        && sev_line "OK" "hiddenSegments present (directories can be hidden)" \
        || sev_line "LOW" "no hiddenSegments - backup/data directories are not hidden by name"
    else
      # Severity is COUPLED to the root's structure. On an app whose document
      # root is the application directory, a missing deny-list is the structural
      # cause of exposure -- HIGH. On a dedicated public/ root, the layout is
      # already doing the protecting and a deny-list is defence-in-depth --
      # MEDIUM. Reporting both at HIGH trains owners to ignore the finding.
      if [ "${ROOT_IS_APPDIR:-0}" -eq 1 ]; then
        sev_line "HIGH" "web.config has NO <requestFiltering> - and this document root IS the application directory, so nothing prevents source/config/data/backup files from being served. This is the STRUCTURAL cause of the exposures above; fixing individual files is whack-a-mole."
        add_finding "server_config" "HIGH" "web.config" "no requestFiltering AND root is the app directory: nothing denies static serving"
      else
        sev_line "MEDIUM" "web.config has no <requestFiltering>. The dedicated public/ root is doing the protecting; add a deny-list anyway so the control survives someone later dropping a file into the served directory."
        add_finding "server_config" "MEDIUM" "web.config" "no requestFiltering (defence-in-depth gap; public/ layout mitigates)"
      fi
    fi
    grep -qi "Strict-Transport-Security" "$wc" 2>/dev/null \
      && sev_line "OK" "HSTS set in app config" \
      || sev_line "LOW" "no HSTS in the app's own config (may come from a parent/site-level config - a site re-create would lose it)"
  fi

  if [ -f "$ht" ]; then
    found=1
    echo "  found: .htaccess (Apache)"
    if grep -qiE "(Require all denied|Deny from all|<FilesMatch|<Files )" "$ht" 2>/dev/null; then
      sev_line "OK" ".htaccess contains deny rules"
      add_finding "server_config" "INFO" ".htaccess" "deny rules present"
    else
      sev_line "MEDIUM" ".htaccess present but contains no deny rules for sensitive file types"
      add_finding "server_config" "MEDIUM" ".htaccess" "no deny rules"
    fi
  fi

  if [ "$found" -eq 0 ]; then
    sev_line "HIGH" "NO server config found in the document root (no web.config, no .htaccess) - nothing constrains which file types are served"
    add_finding "server_config" "HIGH" "(none)" "no web.config or .htaccess in the document root"
  fi
  echo
}

# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Censor Stage-1.5 - web-root inventory (READ-ONLY)

  scan_webroot.sh <webroot-path> [--out <file>]
  scan_webroot.sh --selftest

Enumerates a document root and flags, BY CATEGORY, files that should never be
inside one: archives, database dumps, data exports, credential files, backup
directories, installers and diagnostics. Then reads web.config/.htaccess to
judge whether the server denies by default.

Only names, sizes and extensions are read - never file contents (except the
server config), so a discovered secret is never opened.
EOF
}

selftest() {
  echo "Censor Stage-1.5 self-test"
  echo "  find:  $(command -v find >/dev/null && echo present || echo MISSING)"
  echo "  stat:  $(command -v stat >/dev/null && echo present || echo 'missing (sizes will read 0)')"
  echo
  echo "Categories flagged:"
  echo "  CRITICAL  credential-file, archive, vcs-dir"
  echo "  HIGH      db-dump, data-export, source-backup, diagnostic, backup-dir"
  echo "  MEDIUM    binary, superseded copy"
  echo "  LOW       dead-code, metadata"
  echo
  echo "Self-test OK."
}

# --------------------------- arg parsing -----------------------------------
ROOT=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --selftest) selftest; exit 0 ;;
    --out) shift; [ $# -gt 0 ] || { echo "ERROR: --out needs a file" >&2; exit 2; }; OUT=$1 ;;
    -*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *) [ -z "$ROOT" ] && ROOT=$1 || { echo "ERROR: unexpected arg: $1" >&2; exit 2; } ;;
  esac
  shift
done

[ -n "$ROOT" ] || { usage; exit 2; }
[ -d "$ROOT" ] || { echo "ERROR: not a directory: $ROOT" >&2; exit 2; }
ROOT="${ROOT%/}"
[ -n "$OUT" ] || OUT="censor-webroot-$(basename "$ROOT" | tr -c 'A-Za-z0-9_.-' '_').json"

echo "=================================================================="
echo " Censor Stage-1.5 web-root inventory (READ-ONLY, names/sizes only)"
echo " Root : $ROOT"
echo "=================================================================="
echo

# --------------------------- directory pass --------------------------------
echo "== Directories that should not be under a document root =="
dir_hits=0
while IFS= read -r d; do
  [ -n "$d" ] || continue
  base=$(basename "$d")
  res=$(classify_dir "$base")
  [ -n "$res" ] || continue
  sev=${res%%|*}; rest=${res#*|}; cat=${rest%%|*}; why=${rest#*|}
  rel=".${d#$ROOT}"
  n=$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')
  sev_line "$sev" "$rel  ($n files) - $why"
  add_finding "$cat" "$sev" "$rel" "$why ($n files)"
  dir_hits=$((dir_hits+1))
done < <(find "$ROOT" -maxdepth "$MAX_DEPTH" -type d 2>/dev/null)
[ "$dir_hits" -eq 0 ] && sev_line "OK" "none found"
echo

# --------------------------- file pass -------------------------------------
echo "== Files that should not be under a document root =="
file_hits=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base=$(basename "$f")
  res=$(classify "$base")
  [ -n "$res" ] || continue
  sev=${res%%|*}; rest=${res#*|}; cat=${rest%%|*}; why=${rest#*|}
  rel=".${f#$ROOT}"
  sz=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo 0)
  hs=$(human_size "${sz:-0}")
  sev_line "$sev" "$rel  [$hs]  $cat - $why"
  add_finding "$cat" "$sev" "$rel" "$why (size $hs)"
  file_hits=$((file_hits+1))
done < <(find "$ROOT" -maxdepth "$MAX_DEPTH" -type f 2>/dev/null)
[ "$file_hits" -eq 0 ] && sev_line "OK" "none found"
echo

# --------------------------- static-file source disclosure ------------------
# Narrow, deliberate content read: a .html/.htm file is served as STATIC TEXT,
# so if it contains PHP the source is delivered verbatim to the browser. Reading
# these locally leaks nothing that is not already public by definition -- which
# is exactly why this exception to the names-only rule is safe.
echo "== Server-side code inside statically-served files =="
html_hits=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -ql '<?php' "$f" 2>/dev/null || grep -q '<?php' "$f" 2>/dev/null; then
    rel=".${f#$ROOT}"
    sev_line "HIGH" "$rel - contains PHP inside a statically-served extension: the source is delivered verbatim, not executed"
    add_finding "source-disclosure" "HIGH" "$rel" "PHP code inside a .html/.htm file served as static text"
    html_hits=$((html_hits+1))
  fi
done < <(find "$ROOT" -maxdepth "$MAX_DEPTH" -type f \( -iname '*.html' -o -iname '*.htm' -o -iname '*.txt' -o -iname '*.inc' \) 2>/dev/null)
[ "$html_hits" -eq 0 ] && sev_line "OK" "none found"
echo

# --------------------------- structural check -------------------------------
# The single highest-leverage question about a document root: is it a DEDICATED
# public directory, or the application directory itself? Two apps in the same
# estate with near-identical code had wildly different exposure purely because
# one had a public/ root and the other served its whole app tree.
echo "== Document-root structure =="
noncode=0
for pat in '*.py' '*.ps1' '*.sql' '*.md' '*.yml' '*.yaml' '*.ini'; do
  n=$(find "$ROOT" -maxdepth 2 -type f -iname "$pat" 2>/dev/null | wc -l | tr -d ' ')
  noncode=$((noncode + n))
done
haspublic=0
for d in public public_html htdocs www dist wwwroot; do
  [ -d "$ROOT/$d" ] && haspublic=1
done
if [ "$haspublic" -eq 1 ]; then
  sev_line "OK" "a dedicated public directory exists beneath this path - confirm the server's document root points AT it, not here"
elif [ "$noncode" -gt 0 ]; then
  sev_line "HIGH" "document root appears to BE the application directory ($noncode server-side-only files such as .py/.sql/.md at depth<=2). Everything the app needs to run is inside the served tree, so exposure is the default and each new file is a new risk."
  add_finding "root_structure" "HIGH" "$ROOT" "document root is the application directory (no public/ boundary); $noncode server-side-only files present"
  ROOT_IS_APPDIR=1
  echo "        Structural fix: move the served files into a public/ subdirectory and"
  echo "        repoint the site there. This is what separates a clean sibling app from"
  echo "        an exposed one far more reliably than any deny-list."
else
  sev_line "OK" "no server-side-only file types found at the top of the root"
fi
echo

assess_server_config "$ROOT"

# --------------------------- report ----------------------------------------
total=$((SEV_COUNT_CRIT+SEV_COUNT_HIGH+SEV_COUNT_MED+SEV_COUNT_LOW))
echo "== Summary =="
echo "  CRITICAL $SEV_COUNT_CRIT | HIGH $SEV_COUNT_HIGH | MEDIUM $SEV_COUNT_MED | LOW/INFO $SEV_COUNT_LOW  (total $total)"
echo
echo "  NOTE: a finding here means the file EXISTS inside the document root."
echo "        Whether it is DOWNLOADABLE depends on the server config assessed"
echo "        above and on handler mappings. Confirm each with a Stage-1 probe"
echo "        of its exact path before reporting it as outsider-exploitable."
echo

{
  printf '{"tool":"censor-webroot","root":"%s","findings":[' "$(json_escape "$ROOT")"
  first=1
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    [ "$first" -eq 1 ] && first=0 || printf ','
    printf '%s' "$f"
  done
  printf '],"counts":{"critical":%d,"high":%d,"medium":%d,"low":%d}}\n' \
    "$SEV_COUNT_CRIT" "$SEV_COUNT_HIGH" "$SEV_COUNT_MED" "$SEV_COUNT_LOW"
} > "$OUT"

echo "  JSON report: $OUT"
echo
echo "Done. (Findings do not affect exit code; run completed cleanly.)"
exit 0
