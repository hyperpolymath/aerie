# Aerie — Project-Specific AI Instructions

## Overview

Aerie is a Cyber-Focused Network Diagnostic Suite (CF-NDS). It provides
zero-telemetry network diagnostics with BGP forensics, proof envelopes
for tamper-evident responses, and a policy gate for access control.

## Architecture

- **ABI**: Idris2 (`src/abi/`) — formal type definitions with proofs
- **FFI**: Zig (`ffi/zig/`) — C-compatible implementation layer
- **API Gateway**: V-lang (`src/api/v/`) — GraphQL + REST server on port 4000
- **Probes**: LibreSpeed (speed), Hyperglass (BGP), SmokePing (jitter)
- **Data**: Redis (cache/audit), VerisimDB (bitemporal, future)
- **Container**: Podman Compose with Chainguard base images

## Allowed Languages

| Language | Use Case |
|----------|----------|
| **V-lang** | API gateway, HTTP server, service clients |
| **Idris2** | ABI definitions, type proofs |
| **Zig** | FFI implementation, C ABI bridge |
| **Nickel** | K9 spec assembly |
| **Guile Scheme** | STATE.scm, META.scm, ECOSYSTEM.scm |
| **Bash** | Scripts, automation |

## Build & Run

```bash
# Run all services (gateway + probes + redis)
podman-compose up -d

# Build gateway only
v src/api/v/main.v -o aerie-gateway

# Run tests
cd ffi/zig && zig build test
cd ffi/zig && zig build test-integration
```

## Key Conventions

- All API responses wrapped in `ProofEnvelope` (SHA-256 hash, query ID, timestamp)
- Policy gate checks `X-Api-Key` header (permissive in Phase 1)
- GraphQL schema at `src/api/graphql/schema.graphql`
- Protobuf definitions at `src/api/proto/aerie.proto`
- SCM files ONLY in `.machine_readable/` directory
- SPDX header: `PMPL-1.0-or-later` (never AGPL)

## Service Ports

| Service | Port | Internal |
|---------|------|----------|
| Gateway | 4000 | 4000 |
| LibreSpeed | 8080 | 80 |
| SmokePing | 8081 | 80 |
| Hyperglass | 8082 | 80 |
| Redis | 6379 | 6379 |

## Embedded Repositories

- `bgp-backbone-lab/` — Independent BGP testing infrastructure (own .git)
- `src/hyperglass/` — Hyperglass deployment (own .git, builds as container)

These are NOT submodules — they are embedded independent repos.
