#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

mkdir -p "$REPO_ROOT/.githooks"
cp "$REPO_ROOT/specs/tools/pre-commit" "$REPO_ROOT/.githooks/pre-commit"

# Enable custom hooks path
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$REPO_ROOT" config core.hooksPath .githooks
  echo "Installed pre-commit hook to .githooks/pre-commit"
else
  echo "Not a git repo; skipping git config" >&2
fi
