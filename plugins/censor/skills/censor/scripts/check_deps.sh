#!/usr/bin/env bash
# check_deps.sh — report which Censor scanning tools are available, and the
# OS-appropriate way to install the missing ones. READ-ONLY: it never installs
# anything itself; it only reports. The skill offers to run the install commands
# (with the user's confirmation).
#
# Output contract for the skill:
#   - a human-readable report
#   - one "AVAILABLE: <tools>" line
#   - one "OS: <windows|mac|linux|unknown>" line
#   - an "=== INSTALL COMMANDS ===" block: "<tool><TAB><command-or-GUIDANCE>" per missing tool
#     (GUIDANCE token WINDOWS-SEMGREP = not native on Windows; use WSL/Docker)
set -u

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OS=windows ;;
  Darwin) OS=mac ;;
  Linux)  OS=linux ;;
  *)      OS=unknown ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

# install_cmd <tool> -> the OS-appropriate install command (or a GUIDANCE token)
install_cmd() {
  case "$1:$OS" in
    gitleaks:windows) echo "winget install Gitleaks.Gitleaks" ;;
    gitleaks:mac)     echo "brew install gitleaks" ;;
    gitleaks:linux)   echo "brew install gitleaks   # or download: https://github.com/gitleaks/gitleaks/releases" ;;
    semgrep:windows)  echo "WINDOWS-SEMGREP" ;;
    semgrep:mac)      echo "brew install semgrep   # or: pipx install semgrep" ;;
    semgrep:linux)    echo "pipx install semgrep   # or: pip install semgrep" ;;
    curl:windows)     echo "MANUAL: bundled with Git for Windows (reinstall Git if missing)" ;;
    curl:mac)         echo "brew install curl" ;;
    curl:linux)       echo "sudo apt-get install -y curl   # or: sudo dnf install -y curl" ;;
    openssl:windows)  echo "MANUAL: bundled with Git for Windows" ;;
    openssl:mac)      echo "brew install openssl" ;;
    openssl:linux)    echo "sudo apt-get install -y openssl   # or: sudo dnf install -y openssl" ;;
    *)                echo "MANUAL: see the tool's project page" ;;
  esac
}

echo "Censor dependency check   (OS: $OS)"
echo "------------------------------------"

MISSING=()
check() {
  # $1 tool  $2 purpose
  if have "$1"; then
    printf '  [ok]      %-9s %s\n' "$1" "$2"
  else
    printf '  [MISSING] %-9s %s\n' "$1" "$2"
    MISSING+=("$1")
    if [ "$1" = "semgrep" ] && [ "$OS" = "windows" ]; then
      printf '            NOTE: semgrep has no native Windows support. Use WSL\n'
      printf '            (then pipx install semgrep), Docker (docker pull semgrep/semgrep),\n'
      printf '            or run Censor WITHOUT it — probe + gitleaks + the LLM review still apply.\n'
    else
      printf '            install: %s\n' "$(install_cmd "$1")"
    fi
  fi
}

check curl     "Stage 1 probe (headers/TLS/exposed-paths)"
check semgrep  "Stage 2 rule scan (baseline patterns)"
check gitleaks "Stage 2 secret scan"
check openssl  "Stage 1 TLS cert-expiry (optional)"

have docker && echo "  [info]    docker    present — enables a semgrep fallback if native semgrep is unavailable"

# ── machine-readable block for the skill ──────────────────────────────────────
present=""
for t in curl semgrep gitleaks openssl; do have "$t" && present="$present $t"; done
echo
echo "AVAILABLE:${present:- none}"
echo "OS: $OS"
echo "=== INSTALL COMMANDS ==="
for t in "${MISSING[@]:-}"; do
  [ -z "$t" ] && continue
  printf '%s\t%s\n' "$t" "$(install_cmd "$t")"
done
echo "=== END ==="
echo
echo "Any missing tool degrades gracefully — Censor leans on the LLM review for what a"
echo "missing scanner would have caught, and says so in the coverage note."
