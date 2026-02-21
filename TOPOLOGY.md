<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- TOPOLOGY.md — Project architecture map and completion dashboard -->
<!-- Last updated: 2026-02-19 -->

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
                                            ▼
                        ┌─────────────────────────────────────────┐
                        │           APPLICATION LAYER             │
                        │                                         │
                        │  ┌───────────┐  ┌───────────────────┐  │
                        │  │  GraphQL  │  │   Forensics HUD   │  │
                        │  │  Gateway  │  │ (Dashy/Heimdall)  │  │
                        │  └─────┬─────┘  └────────┬──────────┘  │
                        │        │                 │              │
                        │  ┌─────▼─────┐  ┌────────▼──────────┐  │
                        │  │  Vörðr    │  │  Svalinn (Policy) │  │
                        │  └─────┬─────┘  └────────┬──────────┘  │
                        │        │                 │              │
                        │  ┌─────▼─────┐  ┌────────▼──────────┐  │
                        │  │  selur    │  │   Cerro Torre    │  │
                        │  └─────┬─────┘  └───────────────────┘  │
                        │        │                                │
                        │  ┌─────▼─────┐  ┌───────────────────┐  │
                        │  │ Probes    │  │ Monitoring        │  │
                        │  │(Hyperglass│  │ (SmokePing, Zeek, │  │
                        │  │ LibreSpeed)│  │  Suricata)       │  │
                        │  └─────┬─────┘  └────────┬──────────┘  │
                        └────────│─────────────────│──────────────┘
                                 │                 │
                                 ▼                 ▼
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
                        │  .machine_readable/ (STATE.a2ml)        │
                        └─────────────────────────────────────────┘
```

## Completion Dashboard

```
COMPONENT                          STATUS              NOTES
─────────────────────────────────  ──────────────────  ─────────────────────────────────
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
  Dragonfly (Realtime Cache)        ██████████ 100%    High-throughput cache active
  Virtuoso (Semantic XML)           ████░░░░░░  40%    SPARQL 1.2 integration

REPO INFRASTRUCTURE
  .bot_directives/                  ██████████ 100%    Agent alignment rules
  .machine_readable/                ██████████ 100%    A2ML specs (AI.a2ml)
  Justfile                          ██████████ 100%    Standard build tasks

─────────────────────────────────────────────────────────────────────────────
OVERALL:                            ███████░░░  ~70%   Suite functional, refining scaling
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
                             COMPLETE
```

## Update Protocol

This file is maintained by both humans and AI agents. When updating:

1. **After completing a component**: Change its bar and percentage
2. **After adding a component**: Add a new row in the appropriate section
3. **After architectural changes**: Update the ASCII diagram
4. **Date**: Update the `Last updated` comment at the top of this file

Progress bars use: `█` (filled) and `░` (empty), 10 characters wide.
Percentages: 0%, 10%, 20%, ... 100% (in 10% increments).
