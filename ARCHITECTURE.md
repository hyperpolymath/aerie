# Architecture

<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

> The authoritative architecture map is [`TOPOLOGY.md`](TOPOLOGY.md)
> (visual map + completion dashboard). This file states the architectural
> invariants and the layout rules agents and contributors must respect.
> Last updated: 2026-09-23 (audit remediation).

## Estate architecture law (day 1, non-negotiable)

**ABI = Idris2 · FFI = Zig · API = Zig.**

| Layer | Language | Location |
|-------|----------|----------|
| ABI (formal types + proofs) | Idris2 | `src/abi/` |
| FFI (C-compatible boundary) | Zig | `ffi/zig/` |
| API gateway (GraphQL + REST :4000, gRPC :4001) | Zig | `src/api/zig/`, built by `build.zig` |
| UI (SOC HUD) | AffineScript → typed-wasm | `src/ui/` |
| Specs (K9/SVC, bottom-up) | Nickel + K9 | `specs/` |
| Core experiment | Julia | `src/core/Aerie.jl` |

`src/api/rust/` is **tracked drift**: a pre-law Rust rewrite of the gateway.
It is not the API language here — do not build, extend, or migrate to it.
Its removal is an owner decision (see `ROADMAP.adoc`, Phase 7).

## Directory structure (canonical)

```
.
├── build.zig            # gateway build (zig 0.15.2+; -Dzig-api-* overrides)
├── Containerfile        # 2-stage Chainguard OCI image (wolfi-base → static)
├── compose.yml          # "Forensics Bridge" stack: gateway, librespeed, smokeping, hyperglass, redis
├── Justfile             # task runner (no Makefiles estate-wide)
├── guix.scm             # Guix packaging (primary per language policy)
├── aerie_chora.deed     # repo deed — universal AI entry point (standards#837)
├── aerie-launcher.sh    # standards-compliant launcher (launch-scaffolder generated)
├── configs/             # Nickel (conflow) configuration source
├── contractiles/        # deployment-state contracts (Must/Trust/Dust/Intent)
├── docs/                # human documentation (reports, audits, plans)
├── examples/            # usage examples
├── ffi/zig/             # FFI shared library (separate build.zig)
├── network/             # submodules: BGP lab, IPv6 enforcement, dashboards
├── qubes-sdp/           # submodule: Qubes-SDP integration
├── schemas/             # wire/schema definitions (CUE)
├── specs/               # K9/SVC component specs + guarded rendered outputs
├── src/
│   ├── abi/             # Idris2 ABI (Foreign.idr, Layout.idr, Types.idr)
│   ├── api/zig/         # canonical gateway (main, resolvers, policy, proof, clients)
│   ├── api/graphql/     # GraphQL wire contract
│   ├── api/proto/       # gRPC wire contract
│   ├── api/rust/        # TRACKED DRIFT — not the API language (see above)
│   ├── core/            # Julia core experiment
│   └── ui/              # AffineScript HUD + wasm + css
├── tests/               # test suites (fuzz, idris2 proven-tests format)
└── www/                 # site bundle; canonical .well-known/ metadata
```

## Design principles

1. **Proof on every response.** All gateway responses carry a proof envelope
   (SHA-256 hash + query ID + timestamp; Ed448 signatures planned, Phase 3).
2. **Policy gate first.** No gatekeeperless gateways: every request hits the
   policy gate (`src/api/zig/policy.zig`) before it reaches a backend.
3. **Zero telemetry.** Probes (LibreSpeed, Hyperglass, SmokePing) are
   self-hosted; no third-party telemetry paths exist by design.
4. **Bitemporal audit.** All requests/responses logged to Redis; VerisimDB
   federation (valid-time + tx-time) is the retention target.
5. **Submodules pin estates, not copies.** `network/*` and `qubes-sdp` are
   gitlinks to their own repositories (see `.gitmodules`).

## Security considerations

- Dual-use: private deployment only; public exposure without the Phase 3
  hardening (WAF/mTLS) is strictly discouraged (see `README.md`).
- Secrets are environment-injected; nothing secret is committed.
- FFI `unsafe` blocks are confined to the Zig→C ABI boundary and individually
  classified in `audits/assail-classifications.a2ml`.
