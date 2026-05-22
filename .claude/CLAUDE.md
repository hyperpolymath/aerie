# Aerie — Project-Specific AI Instructions

## Overview

Aerie is a Cyber-Focused Network Diagnostic Suite (CF-NDS). It provides
zero-telemetry network diagnostics with BGP forensics, proof envelopes
for tamper-evident responses, and a policy gate for access control.

## Architecture

Estate architecture law (day 1, non-negotiable): **ABI = Idris2, FFI = Zig,
API = Zig**. Never Zig, Rust, or C for these layers.

- **ABI**: Idris2 (`src/abi/`) — formal type definitions with proofs
- **FFI**: Zig (`ffi/zig/`) — C-compatible implementation layer
- **API Gateway**: Zig (`src/api/zig/`) — GraphQL + REST server on port 4000
- **Probes**: LibreSpeed (speed), Hyperglass (BGP), SmokePing (jitter)
- **Data**: Redis (cache/audit), VerisimDB (bitemporal, future)
- **Container**: Podman Compose with Chainguard base images

Zig (`src/api/v/`) was removed 2026-05-16 (estate-wide V ban). The
`src/api/rust/` crate and the old `MIGRATION.adoc` "→ Rust" text are
off-policy drift — Rust is **not** an API language here; do not build,
extend, or migrate to it. Canonical = the Zig gateway.

## Allowed Languages

| Language | Use Case |
|----------|----------|
| **Idris2** | ABI definitions, type proofs (`src/abi/`) |
| **Zig** | API gateway, HTTP server, service clients, FFI / C ABI bridge |
| **Nickel** | K9 spec assembly |
| **Guile Scheme** | .machine_readable/6a2/STATE.a2ml, .machine_readable/6a2/META.a2ml, .machine_readable/6a2/ECOSYSTEM.a2ml |
| **Bash** | Scripts, automation |

Banned here: Zig, Rust (for api/abi/ffi), TypeScript, Go, raw C.

## Build & Run

```bash
# Run all services (gateway + probes + redis)
podman-compose up -d

# Build gateway only (Idris2 ABI + Zig API/FFI)
zig build -Doptimize=ReleaseSafe   # -> zig-out/bin/aerie-gateway

# Run tests
zig build test
cd ffi/zig && zig build test
cd ffi/zig && zig build test-integration
```

## Key Conventions

- All API responses wrapped in `ProofEnvelope` (SHA-256 hash, query ID, timestamp)
- Policy gate checks `X-Api-Key` header (permissive in Phase 1)
- GraphQL schema at `src/api/graphql/schema.graphql`
- Protobuf definitions at `src/api/proto/aerie.proto`
- SCM files ONLY in `.machine_readable/` directory
- SPDX header: `MPL-2.0` (never AGPL)

## Service Ports

| Service | Port | Internal |
|---------|------|----------|
| Gateway | 4000 | 4000 |
| LibreSpeed | 8080 | 80 |
| SmokePing | 8081 | 80 |
| Hyperglass | 8082 | 80 |
| Redis | 6379 | 6379 |

## Embedded Repositories (Git Submodules)

- `bgp-backbone-lab/` — Independent BGP testing infrastructure (submodule: github.com/hyperpolymath/bgp-backbone-lab)
- `qubes-sdp/` — Qubes Software Development Platform (submodule: github.com/hyperpolymath/qubes-sdp)
- `src/hyperglass/` — Hyperglass looking glass deployment (submodule: github.com/thatmattlove/hyperglass)

These are tracked as git submodules via `.gitmodules`. Each has its own
`.git` directory and independent commit history.
