#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

if [[ ! -f manifest.sha256 ]]; then
  echo "manifest.sha256 missing; run specs/tools/update_manifest.sh" >&2
  exit 1
fi

sha256sum -c manifest.sha256
