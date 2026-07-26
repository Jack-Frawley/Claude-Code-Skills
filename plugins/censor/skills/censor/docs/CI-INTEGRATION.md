# Running Censor in CI (SARIF + gate)

Censor's deterministic core can run in a pipeline so the security baseline is
enforced on every push instead of audited by hand. Two pieces:

- **`--sarif`** — emit `semgrep.sarif` + `gitleaks.sarif`. Upload them to GitHub
  code scanning and findings appear inline on the PR diff and in the Security tab;
  the same files open in the VS Code SARIF viewer.
- **`--fail-on error|high`** — exit non-zero when a finding at/above that level
  exists, so the build fails. `error` = semgrep ERROR, any secret, a web-root
  CRITICAL, or a probe HIGH. `high` also includes semgrep WARNING and web-root HIGH.

```
run_deterministic.sh --source . --sarif --fail-on error --out-dir censor-out
```

Exit codes: `0` clean, `3` gate tripped, `2` bad usage.

## GitHub Actions

semgrep and gitleaks both run on the Linux runner (`pip install semgrep`,
`gitleaks` via its action or a release binary). This scans the repo's own source
on every push/PR.

```yaml
name: censor
on: [push, pull_request]
jobs:
  censor:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write   # required to upload SARIF to code scanning
    steps:
      - uses: actions/checkout@v4
      - name: Install scanners
        run: |
          pip install semgrep
          curl -sSL https://github.com/gitleaks/gitleaks/releases/latest/download/gitleaks_linux_x64.tar.gz | tar -xz -C /usr/local/bin gitleaks
      - name: Censor deterministic scan
        run: |
          bash path/to/censor/scripts/run_deterministic.sh \
            --source . --sarif --fail-on error --out-dir censor-out
      # Upload results even if the gate failed, so reviewers see them on the PR.
      - name: Upload semgrep SARIF
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: censor-out/semgrep.sarif
          category: censor-semgrep
      - name: Upload gitleaks SARIF
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: censor-out/gitleaks.sarif
          category: censor-gitleaks
```

Notes:
- **Windows runners work too** — semgrep installs natively (`pip install semgrep`,
  CE Fall-2025 GA); use `winget install Gitleaks.Gitleaks`. Linux runners are just
  cheaper/faster for CI.
- Start with **`--fail-on error`** (only the serious tier gates the build) and a
  `.censorignore` for any accepted findings, so the pipeline is green on day one
  and only new serious issues break it.
- **Whole-scan vs new-only:** this gate trips on *any* qualifying finding in the
  whole tree. A "fail only on findings new since the last green build" mode
  (snapshot the JSON artifacts, diff on the next run) is a planned follow-up; for
  now, `.censorignore` is how you accept the existing backlog.
- Stage 1 (probe) and Stage 1.5 (web-root inventory) are for **live/deployed**
  targets, not the CI checkout — run those against the running app or its document
  root, not the repo. `--source` is the CI-relevant input.
