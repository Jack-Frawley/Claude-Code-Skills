#!/usr/bin/env bash
# check_deps.sh — report which Censor scanning tools are available, and how to
# install the missing ones. Read-only; never installs anything itself.
set -u

have() { command -v "$1" >/dev/null 2>&1; }

status() {
  # $1 tool, $2 purpose, $3 install-hint
  if have "$1"; then
    printf '  [ok]      %-9s %s\n' "$1" "$2"
  else
    printf '  [MISSING] %-9s %s\n' "$1" "$2"
    printf '            install: %s\n' "$3"
  fi
}

echo "Censor dependency check"
echo "-----------------------"
status curl     "Stage 1 probe (headers/TLS/exposed-paths)"   "https://curl.se/  (bundled with Git for Windows / most Linux)"
status semgrep  "Stage 2 rule scan (baseline patterns)"       "pipx install semgrep  |  brew install semgrep  |  pip install semgrep"
status gitleaks "Stage 2 secret scan"                         "https://github.com/gitleaks/gitleaks/releases  |  brew install gitleaks"
status openssl  "Stage 1 TLS cert-expiry (optional)"          "usually preinstalled; https://www.openssl.org/"
echo
echo "Legend: curl+semgrep+gitleaks give the full deterministic core; openssl only adds"
echo "cert-expiry detail. Any missing tool degrades gracefully — Censor leans on the LLM"
echo "review for what a missing scanner would have caught, and says so in the coverage note."

# Emit a machine-readable line the skill can parse without jq.
present=""
for t in curl semgrep gitleaks openssl; do have "$t" && present="$present $t"; done
echo
echo "AVAILABLE:${present:- none}"
