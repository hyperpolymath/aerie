#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Pre-push DEED gate: shape check always; full ABNF lint when a standards
# checkout is resolvable (estate resolution ladder, launcher README).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

DEED="aerie_chora.deed"
if [ ! -f "$DEED" ]; then
  echo "[validate-deed] ERROR: $DEED missing — every RSR repo carries a repo deed (standards#837)." >&2
  exit 1
fi
head -1 "$DEED" | grep -q 'SPDX-License-Identifier' || { echo "[validate-deed] ERROR: $DEED lacks the SPDX header line" >&2; exit 1; }
grep -q '^(repo-deed' "$DEED" || { echo "[validate-deed] ERROR: $DEED does not open with (repo-deed" >&2; exit 1; }
grep -q ':schema-version "1.0.0"' "$DEED" || { echo "[validate-deed] ERROR: $DEED lacks :schema-version" >&2; exit 1; }

# Full lint when a standards checkout is reachable
for cand in \
  "${HP_ESTATE_ROOT:-}/standards" \
  "${XDG_DATA_HOME:-$HOME/.local/share}/hyperpolymath/standards" \
  "/var/mnt/eclipse/repos/standards" \
  "$HOME/developer/repos/standards" \
  "$HOME/dev/repos/standards" \
  "../../standards" "../standards"; do
  LINT="$cand/1-formats/deed/tools/deed_lint.py"
  if [ -n "$cand" ] && [ -f "$LINT" ] && command -v python3 >/dev/null 2>&1; then
    if python3 "$LINT" "$DEED"; then
      echo "[validate-deed] OK: $DEED (full ABNF lint)"
      exit 0
    else
      echo "[validate-deed] ERROR: $DEED failed the normative ABNF lint" >&2
      exit 1
    fi
  fi
done
echo "[validate-deed] OK: $DEED (shape check; no standards checkout for full lint — run deed_lint.py in CI)"
