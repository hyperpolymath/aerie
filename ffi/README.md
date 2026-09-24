<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Foreign-function-interface layer.

Estate law: FFI = Zig. C-compatible implementation layer with its own build.zig; unsafe blocks are confined to the C ABI boundary and classified in audits/assail-classifications.a2ml.

Self-contained since 2026-09-24: this directory implements the **gnosis server pool** and the **service connector pool** in-repo (declared in `src/abi/Gnosis.idr`, header `zig/include/zig_api.h`), superset-compatible with developer-ecosystem/zig-api — the estate library may replace it if ever published. The **GnosisRequestV2** extension carries the query string and request headers, which the v1 surface strips (v1 starves the policy gate of `X-Api-Key` and the resolvers of query parameters).

| Entry | Purpose |
|-------|---------|
| `zig/build.zig` | Standalone FFI build (libzig_api, libaerie alias, header) |
| `zig/include/zig_api.h` | C ABI header (declared in `src/abi/Gnosis.idr`) |
| `zig/src/lib.zig` | Library root: uapi lifecycle; links all surfaces |
| `zig/src/gnosis.zig` | Threaded HTTP/1.1 edge server pool (`uapi_gnosis_*`) |
| `zig/src/connector.zig` | Outbound HTTP/1.1 connector pool (`uapi_connector_*`) |
| `zig/src/core.zig` | Result/state tags pinned to the header, error slot |
| `zig/src/aerie.zig` | libaerie surface (`aerie_*`, declared in `src/abi/Foreign.idr`) |
| `zig/src/kanren.zig` | UNTRUSTED forensic search engine (`kanren_*`, declared in `src/abi/Forensics.idr`; design: `docs/design/forensic-stack.adoc`) |
| `zig/test/` | Integration tests (libaerie surface) |

Layout assertions: `zig build test` compiles `zig_api.h` and asserts struct offsets/sizes against the Zig `extern struct`s — the header and implementation cannot drift silently.

See [`aerie_chora.deed`](../aerie_chora.deed) for the canonical machine-readable description of this layer.
