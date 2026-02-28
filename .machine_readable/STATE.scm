;; SPDX-License-Identifier: PMPL-1.0-or-later
;; STATE.scm - Project state for aerie

(state
  (metadata
    (version "0.2.0")
    (schema-version "1.0")
    (created "2026-02-01")
    (updated "2026-02-28")
    (project "aerie")
    (repo "hyperpolymath/aerie"))

  (project-context
    (name "Aerie")
    (tagline "Cyber-focused network diagnostic suite")
    (tech-stack ("v-lang" "idris2" "zig" "svalinn" "vordr" "cerro-torre"
                 "selur" "verisimdb" "vql" "redis" "graphql" "grpc"
                 "protobuf" "a2ml")))

  (current-position
    (phase "core-telemetry")
    (overall-completion 40)
    (working-features
      ("K9 specs system"
       "Proof envelope spec"
       "GraphQL schema + generated V interface"
       "gRPC protobuf definitions + generated V interface"
       "Policy gate (Phase 1 permissive)"
       "Bitemporal storage plan"
       "Triple-mount API gateway (GraphQL + gRPC + REST)"
       "LibreSpeed HTTP client"
       "Hyperglass HTTP client"
       "Redis client (cache + audit log)"
       "SHA-256 proof envelopes on all responses"
       "Podman Compose with 5 services"
       "Containerfile for gateway (Chainguard images)"
       "ABI type definitions (Idris2)"
       "FFI implementation (Zig)")))

  (session-history
    (session
      (date "2026-02-28")
      (summary "Phase 1 gateway implementation")
      (changes
        ("Fixed .gitignore AGPL header to PMPL-1.0-or-later"
         "Instantiated ABI/FFI template placeholders (build.zig, integration_test.zig)"
         "Fixed SPDX headers in Zig files (AGPL -> PMPL)"
         "Created .claude/CLAUDE.md with V-lang in allowed languages"
         "Implemented proof envelope module (SHA-256 + UUID v4)"
         "Implemented policy gate (Phase 1 permissive with audit logging)"
         "Implemented Redis client (RESP protocol, cache + audit log)"
         "Implemented LibreSpeed HTTP client"
         "Implemented Hyperglass HTTP client"
         "Implemented GraphQL resolvers"
         "Rewrote gateway as triple-mount server (GraphQL:4000 + gRPC:4001 + REST:4000)"
         "Created Containerfile (Chainguard wolfi-base -> static)"
         "Added gateway service to compose.yml (5 services total)"
         "Updated documentation (STATE.scm, ROADMAP.adoc, TOPOLOGY.md)")))))
