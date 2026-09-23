<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# API plane — triple-mount gateway (GraphQL + REST :4000, gRPC :4001).


The canonical implementation is the Zig gateway (zig/), built by the root build.zig. The Rust crate (rust/) is tracked drift: do not build, extend, or migrate to it.

| Entry | Purpose |
|-------|---------|
| `zig/` | canonical gateway (main, resolvers, policy, proof, service clients) |
| `graphql/` | GraphQL wire contract (schema.graphql) |
| `proto/` | gRPC wire contract (aerie.proto) |
| `rust/` | tracked drift — pre-law Rust rewrite |

See [`aerie_chora.deed`](../../aerie_chora.deed) for the canonical machine-readable description of this layer.
