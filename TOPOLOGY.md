<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- TOPOLOGY.md — Project architecture map and completion dashboard -->
<!-- Last updated: 2026-02-28 -->

# Aerie — Project Topology

## System Architecture

```
                        ┌─────────────────────────────────────────┐
                        │              USERS / CLIENTS            │
                        └───────────────────┬─────────────────────┘
                                            │
                                            ▼
                        ┌─────────────────────────────────────────┐
                        │           CLOUDFLARE (CDN/WAF)          │
                        │    (DNSSEC, Zero Trust, mTLS, WAF)      │
                        └───────────────────┬─────────────────────┘
                                            │
                    ┌───────────────────────────────────────────────┐
                    │           AERIE GATEWAY (V-lang)              │
                    │                                               │
                    │  ┌──────────┐  ┌──────────┐  ┌────────────┐ │
                    │  │ GraphQL  │  │   REST   │  │    gRPC    │ │
                    │  │ :4000    │  │  :4000   │  │   :4001    │ │
                    │  └────┬─────┘  └────┬─────┘  └─────┬──────┘ │
                    │       └─────────────┼──────────────┘         │
                    │                     │                        │
                    │       ┌─────────────▼──────────────┐         │
                    │       │       Policy Gate          │         │
                    │       │   (X-Api-Key, audit log)   │         │
                    │       └─────────────┬──────────────┘         │
                    │                     │                        │
                    │       ┌─────────────▼──────────────┐         │
                    │       │     Proof Envelope         │         │
                    │       │   (SHA-256, UUID, RFC3339) │         │
                    │       └─────────────┬──────────────┘         │
                    └─────────────────────┼────────────────────────┘
                                          │
                    ┌─────────────────────┼────────────────────────┐
                    │                     │                        │
          ┌─────────▼───────┐  ┌──────────▼─────────┐  ┌──────────▼──┐
          │  LibreSpeed     │  │    Hyperglass      │  │    Redis    │
          │  :8080          │  │    :8082           │  │    :6379    │
          │  (speedtest)    │  │    (BGP routes)    │  │ (cache/audit│
          └─────────────────┘  └────────────────────┘  └─────────────┘
                    │
          ┌─────────▼───────┐
          │  SmokePing      │
          │  :8081          │
          │  (jitter)       │
          └─────────────────┘

                        ┌─────────────────────────────────────────┐
                        │           APPLICATION LAYER             │
                        │                                         │
                        │  ┌───────────┐  ┌───────────────────┐  │
                        │  │  Vörðr    │  │  Svalinn (Policy) │  │
                        │  └─────┬─────┘  └────────┬──────────┘  │
                        │        │                 │              │
                        │  ┌─────▼─────┐  ┌────────▼──────────┐  │
                        │  │  selur    │  │   Cerro Torre    │  │
                        │  └─────┬─────┘  └───────────────────┘  │
                        │        │                                │
                        │  ┌─────▼──────────────────────────┐    │
                        │  │ Monitoring (Zeek, Suricata)    │    │
                        │  └────────────────────────────────┘    │
                        └─────────────────────────────────────────┘
                                            │
                                            ▼
                        ┌─────────────────────────────────────────┐
                        │             DATA LAYER                  │
                        │  ┌───────────┐  ┌───────────────────┐  │
                        │  │ VerisimDB │  │    ArangoDB       │  │
                        │  └───────────┘  └───────────────────┘  │
                        │  ┌───────────┐  ┌───────────────────┐  │
                        │  │ Dragonfly │  │    Virtuoso       │  │
                        │  └───────────┘  └───────────────────┘  │
                        └─────────────────────────────────────────┘

                        ┌─────────────────────────────────────────┐
                        │          REPO INFRASTRUCTURE            │
                        │  .bot_directives/   .github/workflows/  │
                        │  contractiles/      justfile            │
                        │  .machine_readable/ (STATE.scm)         │
                        └─────────────────────────────────────────┘
```

## Completion Dashboard

```
COMPONENT                          STATUS              NOTES
─────────────────────────────────  ──────────────────  ─────────────────────────────────
API GATEWAY (Phase 1 ✓)
  Gateway Server (V-lang)          ██████████ 100%    Triple-mount: GraphQL+gRPC+REST
  Policy Gate                      ██████░░░░  60%    Phase 1 permissive, Phase 2 entitlements
  Proof Envelope                   ██████████ 100%    SHA-256 light mode active
  LibreSpeed Client                ██████████ 100%    HTTP client wired
  Hyperglass Client                ██████████ 100%    HTTP client wired
  Redis Client                     ██████████ 100%    Cache + audit log
  Containerfile                    ██████████ 100%    Chainguard multi-stage build
  Compose (5 services)             ██████████ 100%    gateway+librespeed+smokeping+redis+hyperglass

ABI / FFI
  Idris2 ABI Types                 ██████████ 100%    TelemetrySample, RouteHop, AuditEvent
  Zig FFI Implementation           ████████░░  80%    init/free lifecycle, types matched
  Integration Tests                ████████░░  80%    16+ test cases (lifecycle, memory, threads)

SECURITY & VERIFICATION
  Cerro Torre (Bundle Verification) ██████████ 100%    Core logic stable
  Svalinn (Policy Gate)             ██████████ 100%    Policy enforcement active
  Vörðr (Orchestration)             ██████░░░░  60%    Scaling logic in progress
  selur (IPC)                       ████████░░  80%    Wait-free primitives refined

FORENSICS HUD
  LibreSpeed (Zero-telemetry)       ██████████ 100%    Bespoke widget integrated
  Hyperglass (Looking Glass)        ████████░░  80%    MTR output parsing complete
  SmokePing (Jitter)                ██████░░░░  60%    Bitemporal retention pending
  Zeek/Suricata (Passive)           ████░░░░░░  40%    Initial tap points configured

DATA PLANE
  VerisimDB (Federation)            ██████░░░░  60%    VQL implementation ongoing
  ArangoDB (Graph Forensics)        ████████░░  80%    Schema stable
  Redis (Realtime Cache + Audit)    ██████████ 100%    RESP client, cache TTL, audit log
  Virtuoso (Semantic XML)           ████░░░░░░  40%    SPARQL 1.2 integration

REPO INFRASTRUCTURE
  .bot_directives/                  ██████████ 100%    Agent alignment rules
  .machine_readable/                ██████████ 100%    SCM specs
  Justfile                          ██████████ 100%    Standard build tasks
  .claude/CLAUDE.md                 ██████████ 100%    Project-specific AI instructions

─────────────────────────────────────────────────────────────────────────────
OVERALL:                            ████████░░  ~40%   Phase 1 complete, gateway functional
```

## Key Dependencies

```
Cerro Torre ───► Svalinn ───► Vörðr ───► selur
                                │          │
                   ┌────────────┴──────────┼────────────┐
                   ▼                       ▼            ▼
               Probes HUD              Forensics     VerisimDB
                   │                       │            │
                   └────────────┬──────────┴────────────┘
                                ▼
                          Aerie Gateway
                       (GraphQL+gRPC+REST)
                                │
                       ┌────────┼────────┐
                       ▼        ▼        ▼
                   LibreSpeed Hyperglass Redis
```

## Service Ports

| Service | Host Port | Internal Port | Protocol |
|---------|-----------|---------------|----------|
| Gateway (HTTP) | 4000 | 4000 | REST + GraphQL |
| Gateway (gRPC) | 4001 | 4001 | Length-prefixed binary |
| LibreSpeed | 8080 | 80 | HTTP |
| SmokePing | 8081 | 80 | HTTP |
| Hyperglass | 8082 | 80 | HTTP |
| Redis | 6379 | 6379 | RESP |

## Update Protocol

This file is maintained by both humans and AI agents. When updating:

1. **After completing a component**: Change its bar and percentage
2. **After adding a component**: Add a new row in the appropriate section
3. **After architectural changes**: Update the ASCII diagram
4. **Date**: Update the `Last updated` comment at the top of this file

Progress bars use: `█` (filled) and `░` (empty), 10 characters wide.
Percentages: 0%, 10%, 20%, ... 100% (in 10% increments).
