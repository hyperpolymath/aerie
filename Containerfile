# SPDX-License-Identifier: PMPL-1.0-or-later
#
# Containerfile — Aerie Gateway (Triple-Mount API Server)
#
# Estate architecture law: ABI = Idris2 (src/abi/), API + FFI = Zig.
#   The V-lang implementation (src/api/v/) was removed under the estate-wide
#   V-lang ban (deprecated 2026-04-12, removed 2026-05-16). The canonical
#   implementation is the Zig gateway src/api/zig/ built by ./build.zig.
#   (The src/api/rust/ crate and the old V→Rust MIGRATION.adoc are off-policy
#    drift — Rust is not an API language here. Tracked separately for removal.)
#
# Multi-stage build:
#   Stage 1: build libzig_api (developer-ecosystem/zig-api FFI) + aerie-gateway
#   Stage 2: copy the static binary into a minimal Chainguard image
#
# Exposes:
#   4000 — HTTP (REST + GraphQL)
#   4001 — gRPC (length-prefixed binary protocol)
#
# Build:   podman build -t aerie-gateway -f Containerfile .
# Run:     podman run -p 4000:4000 -p 4001:4001 aerie-gateway

# --- Stage 1: Build (Zig) ---
FROM cgr.dev/chainguard/wolfi-base:latest AS builder

# Zig toolchain + git (for the zig-api FFI dependency)
RUN apk add --no-cache zig git

# Build the external zig-api FFI dependency (sparse checkout — same org).
# build.zig accepts -Dzig-api-lib-path / -Dzig-api-include-path overrides;
# CI may instead inject a prebuilt libzig_api and skip this clone.
WORKDIR /deps
RUN git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/hyperpolymath/developer-ecosystem.git && \
    cd developer-ecosystem && \
    git sparse-checkout set zig-api && \
    cd zig-api/ffi/zig && \
    zig build -Doptimize=ReleaseSafe

# Build the aerie-gateway Zig binary against the freshly built zig-api
WORKDIR /app
COPY . .
RUN zig build -Doptimize=ReleaseSafe \
        -Dzig-api-lib-path=/deps/developer-ecosystem/zig-api/ffi/zig/zig-out/lib \
        -Dzig-api-include-path=/deps/developer-ecosystem/zig-api/ffi/zig/zig-out/include && \
    cp zig-out/bin/aerie-gateway /app/aerie-gateway

# --- Stage 2: Runtime ---
FROM cgr.dev/chainguard/static:latest

COPY --from=builder /app/aerie-gateway /aerie-gateway

# HTTP (REST + GraphQL) and gRPC ports
EXPOSE 4000
EXPOSE 4001

ENTRYPOINT ["/aerie-gateway"]
