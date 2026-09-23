# Remediation Plan — aerie (2026-09-23 audit)

<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

Consolidates **every** security and quality finding from (a) the
2026-05-26 estate tech-debt scan, (b) the 2026-05-26 FFI unsafe-block
audit, and (c) the 2026-09-23 comprehensive audit, with its disposition.

Status key: **FIXED** (this pass) · **OWNER** (one-line command provided) ·
**ROADMAP** (issue in ROADMAP.adoc Phase 7) · **BY-DESIGN** (documented
decision).

## Security findings

| # | Finding | Source | Disposition |
|---|---------|--------|-------------|
| S1 | 10 `unsafe` blocks under `src/api/zig/` (UnsafeCode/UnsafeFFI) | panic-attack assail 2026-05-26 | **BY-DESIGN** — each is at the Zig→C ABI boundary, required by the language to call externs; individually classified `legitimate-ffi` in `audits/assail-classifications.a2ml` with rationale |
| S2 | No secret-scanning/CodeQL/Scorecard gaps | CI | **BY-DESIGN** — all present as SHA-pinned estate wrappers; `validation.yml` + pre-push hook add gitleaks leg |
| S3 | Submodule remotes | audit 2026-09-23 | **FIXED (verified)** — all SSH form, compliant with REMOTE-URL-POLICY (SSH-only, no tokens in URLs) |
| S4 | Merge gate inactive: `Optimus-Branch` ruleset **disabled**; `allow_merge_commit: true` vs canon squash-only | measured 2026-09-23 | **OWNER** — exact commands in `docs/REPO-SETTINGS.adoc` §1–2 |
| S5 | 50 `.zig-cache` build artefacts tracked in git | audit 2026-09-23 | **FIXED** — de-tracked, `.gitignore` corrected (they were a leak path for local build state) |
| S6 | Actions permissions / security block / vuln alerts unreadable to audit bot (403) | measured 2026-09-23 | **OWNER** — verify commands in `docs/REPO-SETTINGS.adoc` §3 |

## Quality findings

| # | Finding | Source | Disposition |
|---|---------|--------|-------------|
| Q1 | 6 orphan gitlinks broke `git submodule status` (fatal) | audit 2026-09-23 | **FIXED** — `.gitmodules` mappings added (all 6 repos exist in estate) |
| Q2 | Deno config example (`examples/web-project-deno.json`) | audit 2026-09-23 | **FIXED** — deleted (Deno banned estate-wide 2026-09-22) |
| Q3 | `mise.toml` kitchen-sink pinning banned toolchains (python/go/java/denojs/make) + dead registry names + phantom `[alias]` tasks | audit 2026-09-23 | **FIXED** — aerie toolchain, registry-valid, pinned |
| Q4 | `eclexiaiser.toml` → nonexistent `src/main.rs` (dogfood gate would pass a dead reference) | audit 2026-09-23 | **FIXED** — real path |
| Q5 | `ARCHITECTURE.md` generic filler; `RSR_OUTLINE.adoc` stale template copy; extensionless `MAINTAINERS` scaffold dup with wrong maintainer | audit 2026-09-23 | **FIXED** — rewritten / deleted |
| Q6 | README licence badge said PMPL-1.0 (aerie is not in the PMPL register); broken `<embed>` tag | audit 2026-09-23 | **FIXED** — MPL-2.0/CC-BY-SA-4.0 badges, link form |
| Q7 | `CHANGELOG.md` frozen at 0.3.0 (2026-03-03) | audit 2026-09-23 | **FIXED** — `CHANGELOG.adoc`, refreshed |
| Q8 | `.claude/CLAUDE.md` self-contradiction ("Never Zig, Rust, or C") and Containerfile "zig ban" comment — both contradict the architecture law they quote | audit 2026-09-23 | **FIXED** — the file agents read first now states the law correctly |
| Q9 | No repo deed (dogfood gate requires `<repo>_chora.deed`) | audit 2026-09-23 | **FIXED** — `aerie_chora.deed`, ABNF-validated (`deed_lint.py` exit 0) |
| Q10 | No CRG/TRG record; `just crg-*` recipes read a nonexistent `READINESS.md` | audit 2026-09-23 | **FIXED** — `READINESS.adoc` (CRG D / TRG X, honest evidence tables) |
| Q11 | No per-layer READMEs / `0.1-AI-MANIFEST` / AFFIRMATION / Guix / devcontainer / man pages / issue templates | audit 2026-09-23 | **FIXED** — all added this pass |
| Q12 | Rust workspace had no CI | audit 2026-09-23 | **FIXED** — `rust-ci.yml` (tracked-drift crate stays testable) |
| Q13 | `tests/` had only a fuzz README | audit 2026-09-23 | **FIXED (scaffold)** — Idris2 model suite in proven-tests format; first type-check pending CI (no Idris2 in audit sandbox) |
| Q14 | Proof debt: no proof-bearing files | tech-debt 2026-05-26 | **ROADMAP** — LEAN4 targets specified in ROADMAP Phase 7 (P1–P3) |
| Q15 | `src/stale/hyperglass` vendored upstream (Python/TS artifacts) | audit 2026-09-23 | **ROADMAP** — delete or re-home; owner call (deployment samples may be load-bearing); hygiene-allow entry guards the gate meanwhile |
| Q16 | Benchmark suite absent | audit 2026-09-23 | **ROADMAP** — proven-tests-format benchmarks specified (B1–B2) |
| Q17 | `0-AI-MANIFEST.a2ml` is legacy form | audit 2026-09-23 | **BY-DESIGN** — retained as source; the deed is the canonical AI entry point (template practice: both coexist) |
| Q18 | `boj-build.yml` dormant (localhost endpoint, `continue-on-error`) | audit 2026-09-23 | **ROADMAP** — wire real cartridge endpoint when provisioned (j3) |
| Q19 | dogfood-gate groove check looks at root `.well-known/` (canon moved to `www/.well-known/`, template issue #53) | audit 2026-09-23 | **BY-DESIGN** — warning-only; gate fix is standards-side |
| Q20 | pons-asinorum / panic-attack not run this pass (no cargo in sandbox; panic-attack repo not public) | audit 2026-09-23 | **FIXED (path)** — `validation.yml` runs both in CI on push-to-main + dispatch; panic-attack leg is best-effort with recorded gap |

## Issue creation (Phase 8.3)

The audit bot had no issue-mutation permission; the owner creates the
ROADMAP Phase 7 items with the estate label set (see `.github/labels.json`):

```sh
gh issue create -R hyperpolymath/aerie --label "enhancement" --label "needs-triage" \
  --title "<item id> — <title from ROADMAP Phase 7>" --body-file <(sed -n '/<id>/,/^$/p' ROADMAP.adoc)
```

Suggested columns: `To do` (P*, B*, D*, E*), `Blocked` (j3, g1),
`In review` (nothing yet), `Done` (this plan's FIXED rows).
