#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ensure outputs are writable during regeneration
find "$ROOT_DIR/outputs" -type f -name "*.adoc" -exec chmod u+w {} +

"$ROOT_DIR/tools/apply_banners.py"

cd "$ROOT_DIR"

find outputs -type f -name "*.adoc" -print0 | sort -z | xargs -0 sha256sum > manifest.sha256

# Lock outputs as read-only to prevent manual edits
find "$ROOT_DIR/outputs" -type f -name "*.adoc" -exec chmod u-w {} +

printf "Updated specs/manifest.sha256\n"
