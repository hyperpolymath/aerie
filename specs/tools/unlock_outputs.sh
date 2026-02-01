#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find "$ROOT_DIR/outputs" -type f -name "*.adoc" -exec chmod u+w {} +

printf "Outputs unlocked (writable).\n"
