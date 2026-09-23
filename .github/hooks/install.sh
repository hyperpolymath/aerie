#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Point this clone's git hooks at .github/hooks/ (estate portable-hook
# pattern). Idempotent; safe to re-run.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .github/hooks
git config commit.template .gitmessage
chmod +x .github/hooks/pre-push .github/hooks/commit-msg .github/hooks/scan-secrets.sh .github/hooks/validate-deed.sh 2>/dev/null || true
echo "Installed: core.hooksPath -> .github/hooks (pre-push secret+deed gate active), commit.template -> .gitmessage."
