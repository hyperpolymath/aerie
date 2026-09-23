#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Secret scan on push: gitleaks if available, else a conservative grep
# fallback for high-signal patterns (tokens, keys, passwords in URLs).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if command -v gitleaks >/dev/null 2>&1; then
  exec gitleaks detect --source . --no-git --report-format json --report-path /dev/null --exit-code 1 2>/dev/null || \
    gitleaks detect --source . --no-git --exit-code 1
fi

# Fallback: staged/committed high-signal patterns only (advisory block)
PATTERNS='(ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9]{50,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|BEGIN (RSA|EC|OPENSSH) PRIVATE KEY)'
FOUND=0
while IFS= read -r f; do
  if grep -nE "$PATTERNS" "$f" >/dev/null 2>&1; then
    echo "[scan-secrets] BLOCKED: high-signal secret pattern in $f" >&2
    grep -nE "$PATTERNS" "$f" | head -3 >&2
    FOUND=1
  fi
done < <(git ls-files)
[ "$FOUND" -eq 0 ] && echo "[scan-secrets] OK: no high-signal secret patterns (gitleaks not installed; grep fallback)"
exit "$FOUND"
