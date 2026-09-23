;;; SPDX-License-Identifier: MPL-2.0
;;; Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
;;;
;;; guix.scm — Aerie reproducible toolchain manifest.
;;;
;;; Estate language policy §2 (standards 3-practice/LANGUAGE-POLICY.adoc):
;;; GNU Guix is the primary packaging tier; the sealed Containerfile is the
;;; deployment escape hatch. This file is a *manifest*: every package a
;;; developer or CI runner needs to build, test, and run Aerie, declared
;;; as real, named inputs (no TODO markers, no placeholders).
;;;
;;; Usage:
;;;   guix shell -m guix.scm        # one-shot toolchain shell
;;;   guix environment -m guix.scm  # persistent development environment
;;;
;;; Build-side package derivation (a `define-public aerie` with a source
;;; origin, sha256, and a zig-build system) is ROADMAP Phase 7 — it needs
;;; a source hash and a guix zig build-system integration that this
;;; manifest must not fake.
(inputs
 (specification->package "zig")      ; gateway + FFI (build.zig wants 0.15.2+;
                                     ; the channel zig is the closest real pin —
                                     ; see mise.toml for the exact local pin)
 (specification->package "rust")     ; tracked-drift crate only (src/api/rust)
 (specification->package "rust-cargo")
 (specification->package "julia")    ; core experiment (src/core/Aerie.jl)
 (specification->package "just")     ; estate task runner (no Makefiles)
 (specification->package "podman")   ; container runtime (never Docker)
 (specification->package "git")
 (specification->package "shellcheck")
 (specification->package "typos")
 (specification->package "gitleaks")
 (specification->package "trivy"))
