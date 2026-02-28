;; SPDX-License-Identifier: PMPL-1.0-or-later
;; STATE.scm - Project state for aerie

(state
  (metadata
    (version "0.3.0")
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
    (phase "historical-integrity")
    (overall-completion 55)
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
       "SmokePing HTTP client (smoke charts + latency/jitter)"
       "VerisimDB bitemporal client (as-of, between, history queries)"
       "Dual-tier audit pipeline (Redis hot + VerisimDB cold)"
       "Temporal audit REST/GraphQL/gRPC endpoints"
       "Redis client (cache + audit log)"
       "SHA-256 proof envelopes on all responses"
       "Podman Compose with 6 services (+ VerisimDB)"
       "Containerfile for gateway (Chainguard images)"
       "ABI type definitions (Idris2)"
       "FFI implementation (Zig)")))

  (session-history
    (session
      (date "2026-02-28d")
      (summary "V 0.5.0 compilation fixes — clean build with zero errors/warnings")
      (changes
        ("Fixed http.Server port→addr field change (V 0.5.0 API migration)"
         "Fixed spawn thread safety: RedisClient now heap-allocated (&RedisClient) for safe cross-thread sharing"
         "Replaced deprecated json2.raw_decode() with json2.decode[json2.Any]() in main.v, hyperglass_client.v, librespeed_client.v, verisimdb_client.v"
         "Replaced deprecated .arr() with .as_array() in hyperglass_client.v and verisimdb_client.v"
         "Fixed index_after() returning ?int — added or{} unwrap in extract_string_arg()"
         "Added @[heap] attribute to TrieNode for safe referencing in verb_governance.v"
         "Fixed map pointer access with or{} blocks in trie_insert and trie_lookup"
         "Fixed signed integer shift notice — use u32 intermediate for big-endian length prefix"
         "Removed 5 unused imports (time, x.json2) across hyperglass_client.v, proof.v, redis_client.v, resolvers.v, smokeping_client.v"
         "Fixed unused variable warning for parsed in librespeed_client.v"
         "Verified RSR template placeholders — all {{}} patterns are in bgp-backbone-lab submodule (not aerie proper)"
         "Gateway compiles clean: v src/api/v/ → 3.7 MB ELF x86-64 binary, 0 errors, 0 warnings, 0 notices")))
    (session
      (date "2026-02-28c")
      (summary "Phase 2: SmokePing integration + VerisimDB bitemporal audit")
      (changes
        ("Created smokeping_client.v — HTTP client for SmokePing CGI endpoint, smoke chart data, RRD parsing"
         "Created verisimdb_client.v — VerisimDB bitemporal client with as-of/between/history queries"
         "Added dual_log_audit() — writes to both Redis (hot) and VerisimDB (cold)"
         "Added resolve_smokeping() and resolve_temporal_audit() resolvers with proof envelopes"
         "Added REST endpoints: /api/v1/smokeping, /api/v1/audit/temporal"
         "Added GraphQL queries: smokePingSnapshot(target), temporalAuditSnapshot(mode, ...)"
         "Added gRPC methods: GetSmokePingSnapshot, GetTemporalAuditSnapshot"
         "Updated schema.graphql with SmokePingPayload, SmokePingSample, SmokeChartPoint, TemporalAuditPayload"
         "Updated aerie.proto with SmokePing and TemporalAudit message types and RPCs"
         "Added VerisimDB as 6th service in compose.yml (port 8084, persistent volume)"
         "Gateway version bumped to 0.3.0, 2384 LOC across 10 V files")))
    (session
      (date "2026-02-28b")
      (summary "Block 1 immediate fixes audit and submodule investigation")
      (changes
        ("Verified .gitignore already has PMPL-1.0-or-later (not AGPL)"
         "Verified all 4 ABI/FFI files already instantiated with 'aerie' (no {{project}} placeholders)"
         "Verified V-lang already in .claude/CLAUDE.md allowed languages"
         "Verified compose.yml already has active gateway service (5 services)"
         "Investigated submodule status: bgp-backbone-lab and src/hyperglass tracked as gitlinks (mode 160000) but no .gitmodules file exists — orphaned submodule state"
         "bgp-backbone-lab: embedded repo pointing to hyperpolymath/bgp-backbone-lab, has modified Foreign.idr"
         "src/hyperglass: embedded fork of thatmattlove/hyperglass with local modifications (Dockerfile->Containerfile, route/query changes)"
         "Remaining template placeholders in RSR boilerplate files (CONTRIBUTING.md, CODE_OF_CONDUCT.md, etc.) noted for future cleanup")))
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
