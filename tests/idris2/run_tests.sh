#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Run the aerie Idris2 model suite. Exit codes: 0 = pass, 1 = failed check,
# 2/other = toolchain or build problem (NEVER a silent pass).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
command -v idris2 >/dev/null 2>&1 || { echo "idris2 not found (install from idris2.org)"; exit 2; }
idris2 --build Test
idris2 aerie-tests
