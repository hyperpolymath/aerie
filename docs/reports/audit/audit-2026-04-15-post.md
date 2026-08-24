# Post-audit Status Report: aerie
- **Date:** 2026-04-15
- **Status:** Complete (M5 Sweep)
- **Repo:** /var/mnt/eclipse/repos/aerie

## Actions Taken
1. Standard CI/Workflow Sweep: Added blocker workflows (`ts-blocker.yml`, `npm-bun-blocker.yml`) and updated `Justfile`.
2. SCM-to-A2ML Migration: Staged and committed deletions of legacy `.scm` files.
3. Lockfile Sweep: Generated and tracked missing lockfiles where manifests were present.
4. Static Analysis: Verified with `panic-attack assail`.

## Findings Summary
- 14 TODO/FIXME/HACK markers in contractiles/k9/template-hunt.k9.ncl
- 2 HTTP (non-HTTPS) URLs in src/api/v/librespeed_client.v
- 2 HTTP (non-HTTPS) URLs in src/api/v/hyperglass_client.v
- 3 HTTP (non-HTTPS) URLs in src/api/v/smokeping_client.v
- 3 HTTP (non-HTTPS) URLs in src/api/v/main.v
- 4 HTTP (non-HTTPS) URLs in src/api/v/verisim_client.v
- 8 HTTP (non-HTTPS) URLs in src/api/rust/src/backends.rs
- Hardcoded /tmp/ path without mktemp in src/stale/hyperglass/.tests/ga-backend-app.sh
- 14 TODO/FIXME/HACK markers in bgp-backbone-lab/contractiles/k9/template-hunt.k9.ncl
- 14 TODO/FIXME/HACK markers in qubes-sdp/contractiles/k9/template-hunt.k9.ncl
- eval usage in qubes-sdp/qubes-setup-advanced.sh
- Hardcoded /tmp/ path without mktemp in qubes-sdp/qubes-setup-advanced.sh
- eval usage in qubes-sdp/qubes-setup.sh
- Hardcoded /tmp/ path without mktemp in qubes-sdp/qubes-setup.sh
- eval usage in qubes-sdp/scripts/rsr-verify.sh
- eval usage in qubes-sdp/tests/integration-tests.sh
- eval usage in qubes-sdp/tests/security-tests.sh
- eval usage in qubes-sdp/tests/unit-tests.sh
- Hardcoded /tmp/ path without mktemp in qubes-sdp/tools/qubes-policy-generator.sh
- flake.guix declares inputs without narHash, rev pinning, or sibling flake.lock — dependency revision is unpinned in flake.guix
- 23 potentially unquoted variable expansions in aerie-launcher.sh
- Hardcoded /tmp/ path without mktemp in aerie-launcher.sh
- Rust project has test infrastructure but no mutation-test configuration (cargo-mutants/.cargo-mutants.toml) — add `cargo mutants` to verify test suite kills mutations

## Final Grade
- **CRG Grade:** D (Promoted from E/X) - CI and lockfiles are in place.
