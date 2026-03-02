# URGENT: ReScript Migration Required

**Generated:** 2026-03-02
**Current stable ReScript:** 12.2.0
**Pre-release:** 13.0.0-alpha.2 (2025-02-27)

This repo has ReScript code that needs migration. Address in priority order.

## CHECK: Version Unknown or Unpinned

- `qubes-sdp (no version pinned)`

**Action:** Pin to `"rescript": "^12.2.0"` explicitly.

---

## ReScript 13 Preparation (v13.0.0-alpha.2 available)

v13 is in alpha. These breaking changes are CONFIRMED — prepare now:

1. **`bsconfig.json` support removed** — must use `rescript.json` only
2. **`rescript-legacy` command removed** — only modern build system
3. **`bs-dependencies`/`bs-dev-dependencies`/`bsc-flags` config keys removed**
4. **Uncurried `(. args) => ...` syntax removed** — use standard `(args) => ...`
5. **`es6`/`es6-global` module format names removed** — use `esmodule`
6. **`external-stdlib` config option removed**
7. **`--dev`, `--create-sourcedirs`, `build -w` CLI flags removed**
8. **`Int.fromString`/`Float.fromString` API changes** — no explicit radix arg
9. **`js-post-build` behaviour changed** — now passes correct output paths

**Migration path:** Complete all v12 migration FIRST, then test against v13-alpha.
