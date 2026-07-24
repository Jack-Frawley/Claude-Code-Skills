#!/usr/bin/env bash
#
# Censor - Stage-1 black-box recon probe
#
# READ-ONLY, non-intrusive reconnaissance of a web app the operator is
# AUTHORIZED to audit. Only issues GET/HEAD requests. No injection payloads,
# no brute force, no fuzzing floods, strict timeouts on every network call.
#
# It NEVER stores or prints response BODIES of the exposed-path probes:
# exposure is confirmed by status code / headers only, secrets are never
# captured or exfiltrated.
#
# Portable: runs under Git Bash on Windows and native Linux/macOS bash.
# Depends only on `curl` (assumed present); uses `openssl` if available and
# degrades gracefully if it is not. Does NOT require `jq`.
#
# Usage:
#   probe.sh <base-url>                         e.g. probe.sh https://example.com
#   probe.sh <base-url> --paths <file>          add operator-supplied extra paths
#   probe.sh <base-url> --out <file>            override the JSON output path
#   probe.sh --selftest                         verify deps + print catalog, no network
#
# Exit status: 0 on a completed run (findings do NOT change exit code),
# non-zero ONLY on script misuse (bad args, missing url, unreadable paths file).

set -u

# ---------------------------------------------------------------------------
# Constants / tunables
# ---------------------------------------------------------------------------
CONNECT_TIMEOUT=8
MAX_TIME=15
MAX_REDIRS=5
UA="Censor-Stage1-Probe/1.0 (authorized-audit; read-only)"

# Curated, read-only exposed-path list shipped with the probe.
EXPOSED_PATHS=(
  "/.git/config"
  "/.git/HEAD"
  "/.env"
  "/config.php"
  "/composer.json"
  "/composer.lock"
  "/phpinfo.php"
  "/info.php"
  "/server-status"
  "/server-info"
  "/.htaccess"
  "/web.config"
  "/backup.zip"
  "/backup.sql"
  "/db.sql"
  "/.DS_Store"
  "/storage/logs/"
  "/vendor/"
  "/.vscode/"
  "/debug.log"
  "/tokens.json"
  "/token.json"
  "/secrets.json"
  "/credentials.json"
  "/.npmrc"
  "/.pypirc"
  "/id_rsa"
  "/.aws/credentials"
  # Conventional config/backup names a deny-by-default rule should be blocking (§9).
  "/appsettings.json"
  "/config.json"
  "/.env.local"
  "/.env.production"
  "/dump.sql"
)

SECURITY_HEADERS=(
  "Content-Security-Policy"
  "X-Frame-Options"
  "X-Content-Type-Options"
  "Referrer-Policy"
  "Strict-Transport-Security"
)

# ---------------------------------------------------------------------------
# Findings accumulator (array of pre-escaped JSON objects)
# ---------------------------------------------------------------------------
FINDINGS=()

# JSON string escaper (backslash, quote, control chars) - no jq required.
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# add_finding <check> <severity> <detail> <evidence>
add_finding() {
  local check=$1 sev=$2 detail=$3 evidence=$4
  FINDINGS+=("$(printf '{"check":"%s","severity":"%s","detail":"%s","evidence":"%s"}' \
    "$(json_escape "$check")" "$(json_escape "$sev")" \
    "$(json_escape "$detail")" "$(json_escape "$evidence")")")
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Censor Stage-1 recon probe (READ-ONLY, authorized audit use only)

Usage:
  probe.sh <base-url> [--paths <file>] [--out <file>]
  probe.sh --selftest

  <base-url>        Target, e.g. https://example.com (http:// or https://)
  --paths <file>    Extra newline-delimited paths to probe (app-specific)
  --out <file>      JSON output path (default: ./censor-probe-<host>.json)
  --selftest        Verify dependencies and print the check catalog; no network

Notes:
  * Only GET/HEAD requests are issued. No payloads, brute force, or fuzzing.
  * Response bodies of exposed-path probes are never stored or printed.
  * Exit is non-zero only on misuse; findings never change the exit code.
EOF
}

sev_line() { printf '  [%-4s] %s\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
# Catalog (used by --selftest and for operator transparency)
# ---------------------------------------------------------------------------
print_catalog() {
  echo "Check catalog:"
  echo
  echo "1. Security headers (via curl -sI, redirects followed up to ${MAX_REDIRS}):"
  local h
  for h in "${SECURITY_HEADERS[@]}"; do
    echo "     - ${h}"
  done
  echo "     - Server: banner (version-disclosure note)"
  echo
  echo "2. TLS / transport:"
  echo "     - https reachability"
  echo "     - http -> https redirect (status + Location)"
  echo "     - certificate notAfter/expiry (openssl, if available)"
  echo "     - HTTP-only (no HTTPS) flagged HIGH"
  echo
  echo "3. Exposed-path probes (HEAD, --max-redirs 0, body never stored):"
  local p
  for p in "${EXPOSED_PATHS[@]}"; do
    echo "     - ${p}"
  done
  echo
  echo "   200 => finding (exposed); 401/403 => blocked (good); 3xx/404 => ignored."
  echo "   For 200s, Content-Type and Content-Length are captured (status only,"
  echo "   never the body)."
  echo
  echo "4. Optional operator-supplied extra paths via --paths <file>."
}

# ---------------------------------------------------------------------------
# Dependency detection
# ---------------------------------------------------------------------------
HAVE_OPENSSL=0
HAVE_TIMEOUT=0
detect_deps() {
  if command -v openssl >/dev/null 2>&1; then HAVE_OPENSSL=1; fi
  if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=1; fi
}

# Run a command under a wall-clock timeout if `timeout` exists; else run bare.
guarded() {
  local secs=$1; shift
  if [ "$HAVE_TIMEOUT" -eq 1 ]; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
selftest() {
  detect_deps
  echo "== Censor Stage-1 probe :: self-test =="
  echo
  echo "Dependencies:"
  if command -v curl >/dev/null 2>&1; then
    printf '  [ OK ] curl        %s\n' "$(curl --version 2>/dev/null | head -1)"
  else
    printf '  [FAIL] curl        NOT FOUND (required)\n'
  fi
  if [ "$HAVE_OPENSSL" -eq 1 ]; then
    printf '  [ OK ] openssl     %s\n' "$(openssl version 2>/dev/null)"
  else
    printf '  [WARN] openssl     not found (cert-expiry check will be skipped)\n'
  fi
  if [ "$HAVE_TIMEOUT" -eq 1 ]; then
    printf '  [ OK ] timeout     present (openssl call will be wall-clock guarded)\n'
  else
    printf '  [INFO] timeout     not found (openssl relies on its own -connect timeout)\n'
  fi
  echo
  print_catalog
  echo
  if command -v curl >/dev/null 2>&1; then
    echo "Self-test OK: required dependency (curl) present."
    return 0
  fi
  echo "Self-test FAILED: curl is required."
  return 1
}

# ---------------------------------------------------------------------------
# Header extraction helper
# ---------------------------------------------------------------------------
# get_header <header-name> <header-blob>  -> last matching value (trimmed)
get_header() {
  local name=$1 blob=$2 line val
  line=$(printf '%s\n' "$blob" | grep -i "^[[:space:]]*${name}:" | tail -1)
  [ -z "$line" ] && return 1
  val=${line#*:}
  # trim leading/trailing whitespace and CR
  val=${val%$'\r'}
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

# get_status <header-blob> -> last HTTP status code (e.g. 200)
get_status() {
  local blob=$1
  printf '%s\n' "$blob" | grep -iE '^HTTP/' | tail -1 | awk '{print $2}'
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
run_header_checks() {
  local base=$1
  echo "== Headers =="
  local blob rc
  blob=$(curl -sSIL -A "$UA" \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    --max-redirs "$MAX_REDIRS" "$base" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$blob" ]; then
    sev_line "MED" "Could not retrieve response headers (curl exit ${rc})."
    add_finding "headers.reachability" "MED" \
      "Could not retrieve response headers" "curl exit ${rc} for ${base}"
    echo
    return 0
  fi

  local h val
  for h in "${SECURITY_HEADERS[@]}"; do
    if val=$(get_header "$h" "$blob"); then
      sev_line "INFO" "${h}: present"
      add_finding "headers.${h}" "INFO" "${h} present" "$val"
    else
      local sev="MED"
      [ "$h" = "Referrer-Policy" ] && sev="LOW"
      sev_line "$sev" "${h}: MISSING"
      add_finding "headers.${h}" "$sev" "${h} missing" ""
    fi
  done

  # Server banner / version disclosure
  local server
  if server=$(get_header "Server" "$blob"); then
    if printf '%s' "$server" | grep -qE '[0-9]+\.[0-9]+'; then
      sev_line "LOW" "Server banner discloses version: ${server}"
      add_finding "headers.Server" "LOW" \
        "Server banner discloses version" "$server"
    else
      sev_line "INFO" "Server banner: ${server}"
      add_finding "headers.Server" "INFO" "Server banner present" "$server"
    fi
  else
    sev_line "INFO" "Server banner: not disclosed (good)"
    add_finding "headers.Server" "INFO" "Server banner not disclosed" ""
  fi
  echo
}

run_transport_checks() {
  local host=$1 scheme=$2
  echo "== Transport / TLS =="
  local https_url="https://${host}"
  local http_url="http://${host}"

  # HTTPS reachability
  local hblob hstatus
  hblob=$(curl -sSI -A "$UA" \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    --max-redirs "$MAX_REDIRS" "$https_url" 2>/dev/null)
  hstatus=$(get_status "$hblob")
  local https_ok=0
  if [ -n "$hstatus" ]; then
    https_ok=1
    sev_line "INFO" "HTTPS reachable (status ${hstatus})."
    add_finding "transport.https" "INFO" "HTTPS reachable" "status ${hstatus}"
  else
    sev_line "INFO" "HTTPS did not respond."
    add_finding "transport.https" "INFO" "HTTPS did not respond" "$https_url"
  fi

  # HTTP -> HTTPS redirect behaviour
  local pblob pstatus ploc
  pblob=$(curl -sSI -A "$UA" \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    --max-redirs 0 "$http_url" 2>/dev/null)
  pstatus=$(get_status "$pblob")
  if [ -z "$pstatus" ]; then
    if [ "$https_ok" -eq 1 ]; then
      sev_line "INFO" "HTTP did not respond (HTTPS-only). Fine."
      add_finding "transport.http_redirect" "INFO" \
        "HTTP did not respond; HTTPS-only" "$http_url"
    else
      sev_line "INFO" "Neither HTTP nor HTTPS responded on ${host}."
      add_finding "transport.reachability" "INFO" \
        "Neither HTTP nor HTTPS responded" "$host"
    fi
  else
    ploc=$(get_header "Location" "$pblob" || true)
    case "$pstatus" in
      30*)
        if printf '%s' "$ploc" | grep -qiE '^https://'; then
          sev_line "INFO" "HTTP redirects to HTTPS (status ${pstatus})."
          add_finding "transport.http_redirect" "INFO" \
            "HTTP redirects to HTTPS" "status ${pstatus} -> ${ploc}"
        else
          sev_line "MED" "HTTP redirects but not to HTTPS (status ${pstatus}, Location: ${ploc})."
          add_finding "transport.http_redirect" "MED" \
            "HTTP redirect target is not HTTPS" "status ${pstatus} -> ${ploc}"
        fi
        ;;
      *)
        if [ "$https_ok" -eq 1 ]; then
          sev_line "MED" "HTTP serves content without redirecting to HTTPS (status ${pstatus})."
          add_finding "transport.http_redirect" "MED" \
            "HTTP does not redirect to HTTPS" "status ${pstatus}"
        else
          sev_line "HIGH" "HTTP-only: site served over plaintext HTTP with no HTTPS (status ${pstatus})."
          add_finding "transport.http_only" "HIGH" \
            "Site served over plaintext HTTP with no HTTPS" "status ${pstatus}"
        fi
        ;;
    esac
  fi

  # Certificate expiry (openssl, guarded, optional)
  if [ "$https_ok" -eq 1 ]; then
    if [ "$HAVE_OPENSSL" -eq 1 ]; then
      local enddate
      enddate=$(guarded "$MAX_TIME" openssl s_client -connect "${host}:443" \
        -servername "$host" </dev/null 2>/dev/null \
        | guarded "$MAX_TIME" openssl x509 -noout -enddate 2>/dev/null)
      enddate=${enddate#notAfter=}
      enddate=${enddate%$'\r'}
      if [ -n "$enddate" ]; then
        sev_line "INFO" "Certificate notAfter: ${enddate}"
        add_finding "transport.cert_expiry" "INFO" \
          "Certificate expiry (notAfter)" "$enddate"
      else
        sev_line "INFO" "Certificate expiry: could not be read via openssl."
        add_finding "transport.cert_expiry" "INFO" \
          "Certificate expiry unreadable" "openssl returned no enddate"
      fi
    else
      sev_line "INFO" "Certificate expiry: openssl unavailable (skipped)."
      add_finding "transport.cert_expiry" "INFO" \
        "Certificate expiry not checked" "openssl unavailable"
    fi
  fi
  echo
}

# probe_one_path <base> <path> [origin]  -> prints one line, records finding
# origin: "curated" (default) or "operator". Operator-supplied paths are named
# deliberately, so their mere existence is signal and 3xx is reported rather than
# dropped; curated paths still ignore 3xx to avoid one noise finding per path on
# auth-gated sites.
probe_one_path() {
  local base=$1 path=$2 origin=${3:-curated}
  # Ensure exactly one slash join.
  local full="${base%/}${path}"
  local blob status ctype clen
  # HEAD request, redirects blocked so a catch-all redirect cannot mask a 404
  # as a 200. Headers captured only; body is never requested or stored.
  blob=$(curl -sSI -A "$UA" \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    --max-redirs 0 "$full" 2>/dev/null)
  status=$(get_status "$blob")
  [ -z "$status" ] && status="---"

  case "$status" in
    200)
      ctype=$(get_header "Content-Type" "$blob" || true)
      clen=$(get_header "Content-Length" "$blob" || true)
      [ -z "$ctype" ] && ctype="unknown"
      [ -z "$clen" ] && clen="unknown"
      if [ "$origin" = "operator" ]; then
        # An operator supplies paths to get their STATUS, not because each is
        # inherently secret — many are ordinary pages, and a 200 on a homepage is
        # expected. The probe cannot tell a leaked credential file from an app page,
        # so it discriminates on what is being SERVED: file/data content types are a
        # finding; an HTML page is an observation for the reviewer to classify.
        case "$ctype" in
          *text/html*|*application/xhtml*)
            sev_line "INFO" "${path} -> 200 reachable (${ctype}) — page; classify by behaviour, not status"
            add_finding "path_reachable" "INFO" \
              "${path} returned 200 (page reachable — not an exposure by itself)" \
              "status 200; Content-Type: ${ctype}; Content-Length: ${clen}"
            ;;
          *)
            sev_line "HIGH" "${path} -> 200 SERVES FILE/DATA (Content-Type: ${ctype}, Content-Length: ${clen})"
            add_finding "exposed_path" "HIGH" \
              "${path} returned 200 serving non-HTML content (${ctype})" \
              "status 200; Content-Type: ${ctype}; Content-Length: ${clen}"
            ;;
        esac
      else
        # Curated paths are ones that must NEVER return 200 (.env, .git/config,
        # phpinfo). Here a 200 is unambiguous regardless of content type.
        sev_line "HIGH" "${path} -> 200 EXPOSED (Content-Type: ${ctype}, Content-Length: ${clen})"
        add_finding "exposed_path" "HIGH" \
          "${path} returned 200 (exposed)" \
          "status 200; Content-Type: ${ctype}; Content-Length: ${clen}"
      fi
      ;;
    403)
      sev_line "INFO" "${path} -> 403 blocked (good)"
      add_finding "exposed_path" "INFO" "${path} returned 403 (blocked)" "status 403"
      ;;
    401)
      sev_line "INFO" "${path} -> 401 auth-required (blocked, good)"
      add_finding "exposed_path" "INFO" "${path} returned 401 (auth required)" "status 401"
      ;;
    404)
      : # ignored per spec
      ;;
    30*)
      # A redirect usually means an auth gate or catch-all rather than a served
      # file, so curated paths stay quiet (one noise finding per path otherwise).
      # But two things about a 3xx ARE real signal and are always reported:
      local loc
      loc=$(get_header "Location" "$blob" || true)
      [ -z "$loc" ] && loc="(no Location header)"

      # (1) HTTPS -> plaintext HTTP downgrade. Never noise, never acceptable:
      # the browser follows it in the clear, exposing cookies and any credentials
      # submitted at the destination. Reported for curated and operator paths alike.
      case "$base" in
        https://*)
          case "$loc" in
            http://*)
              sev_line "HIGH" "${path} -> ${status} DOWNGRADES to plaintext HTTP (${loc})"
              add_finding "redirect_downgrade" "HIGH" \
                "${path} redirects from HTTPS to plaintext HTTP" \
                "status ${status}; Location: ${loc}"
              ;;
          esac
          ;;
      esac

      # (2) An operator-supplied path that redirects still EXISTS. A 302 to a login
      # page is the no-credential path; a page that trusts a forged cookie does not
      # redirect. Reporting existence keeps legacy/bypass pages visible.
      if [ "$origin" = "operator" ]; then
        # INFO, not a defect: a redirect to a login page is usually correct gating.
        # It is recorded because EXISTENCE is the signal — a legacy page that should
        # have been deleted still being present, and a page that trusts a forged
        # cookie would not redirect at all. The reviewer decides which this is.
        sev_line "INFO" "${path} -> ${status} exists (redirects to ${loc})"
        add_finding "path_exists_redirect" "INFO" \
          "${path} exists and redirects (existence noted; not proof of remediation)" \
          "status ${status}; Location: ${loc}"
      fi
      ;;
    ---)
      : # no response; not a finding
      ;;
    *)
      sev_line "LOW" "${path} -> ${status}"
      add_finding "exposed_path" "LOW" "${path} returned ${status}" "status ${status}"
      ;;
  esac
}

run_exposed_path_checks() {
  local base=$1 extra_file=$2
  echo "== Exposed paths =="
  echo "  (200 = finding, 401/403 = blocked/good, 404 = ignored; bodies never stored)"
  echo "  (3xx: HTTPS->HTTP downgrade always reported; operator paths report existence)"
  local before=${#FINDINGS[@]}
  local tested=0
  local p
  for p in "${EXPOSED_PATHS[@]}"; do
    probe_one_path "$base" "$p"
    tested=$((tested+1))
  done

  if [ -n "$extra_file" ]; then
    echo "  -- operator-supplied paths (${extra_file}) --"
    local line
    while IFS= read -r line || [ -n "$line" ]; do
      # skip blanks and comments
      case "$line" in
        ""|\#*) continue ;;
      esac
      # ensure leading slash
      case "$line" in
        /*) : ;;
        *) line="/$line" ;;
      esac
      probe_one_path "$base" "$line" "operator"
      tested=$((tested+1))
    done < "$extra_file"
  fi

  # Count HIGH exposed findings recorded during this section.
  local after=${#FINDINGS[@]}
  local i high=0
  for ((i=before; i<after; i++)); do
    case "${FINDINGS[$i]}" in
      *'"check":"exposed_path","severity":"HIGH"'*) high=$((high+1)) ;;
    esac
  done
  if [ "$high" -eq 0 ]; then
    sev_line "OK" "None of the ${tested} tested paths returned 200."
  fi
  # Coverage honesty: a curated list finds CONVENTIONAL exposures (.env, .git,
  # phpinfo). It cannot find site-specific filenames someone invented. Saying
  # "clean" unqualified invites reading this as an all-clear, which it is not.
  echo "  NOTE: ${tested} paths tested (curated list${extra_file:+ + operator-supplied}). This list is"
  echo "        NOT exhaustive — it cannot know site-specific filenames. A clean result means"
  echo "        the TESTED paths were not exposed, NOT that nothing is exposed. Enumerate the"
  echo "        web root from the filesystem/source for that assurance."
  echo
}

# ---------------------------------------------------------------------------
# JSON writer
# ---------------------------------------------------------------------------
write_json() {
  local out=$1 target=$2 host=$3
  local body="" i
  local n=${#FINDINGS[@]}
  for ((i=0; i<n; i++)); do
    if [ "$i" -gt 0 ]; then body="${body},"; fi
    body="${body}
    ${FINDINGS[$i]}"
  done
  {
    printf '{\n'
    printf '  "tool": "censor-stage1-probe",\n'
    printf '  "target": "%s",\n' "$(json_escape "$target")"
    printf '  "host": "%s",\n' "$(json_escape "$host")"
    printf '  "findings": [%s\n  ]\n' "$body"
    printf '}\n'
  } > "$out"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
main() {
  if [ "$#" -eq 0 ]; then
    usage
    return 2
  fi

  if [ "$1" = "--selftest" ]; then
    selftest
    return $?
  fi

  if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    return 0
  fi

  local base="" paths_file="" out_file=""
  base=$1
  shift

  case "$base" in
    --*)
      echo "ERROR: expected a <base-url> as the first argument." >&2
      usage
      return 2
      ;;
  esac

  # Parse remaining flags.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --paths)
        shift
        if [ "$#" -eq 0 ]; then
          echo "ERROR: --paths requires a file argument." >&2
          return 2
        fi
        paths_file=$1
        ;;
      --out)
        shift
        if [ "$#" -eq 0 ]; then
          echo "ERROR: --out requires a file argument." >&2
          return 2
        fi
        out_file=$1
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        usage
        return 2
        ;;
    esac
    shift
  done

  # Validate URL shape.
  case "$base" in
    http://*|https://*) : ;;
    *)
      echo "ERROR: base-url must start with http:// or https:// (got: '${base}')." >&2
      usage
      return 2
      ;;
  esac

  # Derive host (strip scheme, then path) and scheme.
  local scheme host
  scheme=${base%%://*}
  host=${base#*://}
  host=${host%%/*}
  if [ -z "$host" ]; then
    echo "ERROR: could not parse host from '${base}'." >&2
    return 2
  fi

  if [ -n "$paths_file" ] && [ ! -r "$paths_file" ]; then
    echo "ERROR: --paths file not found or unreadable: '${paths_file}'." >&2
    return 2
  fi

  # Sanitize host for filename (strip port too via non-alnum replace).
  local sanitized
  sanitized=$(printf '%s' "$host" | tr -c 'A-Za-z0-9' '_')
  # collapse any trailing underscores for tidiness
  sanitized=${sanitized%_}
  [ -z "$sanitized" ] && sanitized="target"

  if [ -z "$out_file" ]; then
    out_file="./censor-probe-${sanitized}.json"
  fi

  detect_deps

  if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required but was not found in PATH." >&2
    return 3
  fi

  echo "=================================================================="
  echo " Censor Stage-1 recon probe (READ-ONLY, authorized audit)"
  echo " Target : ${base}"
  echo " Host   : ${host}"
  echo "=================================================================="
  echo

  run_header_checks "$base"
  run_transport_checks "$host" "$scheme"
  run_exposed_path_checks "$base" "$paths_file"

  write_json "$out_file" "$base" "$host"

  echo "== Summary =="
  echo "  Findings recorded : ${#FINDINGS[@]}"
  echo "  JSON report       : ${out_file}"
  echo
  echo "Done. (Findings do not affect exit code; run completed cleanly.)"
  return 0
}

main "$@"
exit $?
