<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Source code, organised by architectural layer.


Estate architecture law: ABI = Idris2, FFI = Zig, API = Zig.

| Entry | Purpose |
|-------|---------|
| `abi/` | Idris2 ABI: formal types with proofs |
| `api/` | API plane (Zig gateway + wire contracts + tracked-drift Rust) |
| `core/` | Julia core experiment (Aerie.jl) |
| `ui/` | SOC HUD front-end (AffineScript/wasm/css) |
| `stale/` | Vendored upstream copies; explicitly stale, not referenced from live code |

See [`aerie_chora.deed`](../aerie_chora.deed) for the canonical machine-readable description of this layer.
