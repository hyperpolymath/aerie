# SPDX-License-Identifier: MPL-2.0
#
# Containerfile — Aerie Gateway (Triple-Mount API Server)
#
# Estate architecture law: ABI = Idris2 (src/abi/), FFI = Zig (ffi/zig/),
# API = Zig (src/api/zig/). The gateway and its FFI (gnosis server +
# connector pool) build together from this repository — no external
# clones, no absolute paths, no private dependencies.
#
# Multi-stage build:
#   Stage 1: zig build -Doptimize=ReleaseSafe  → aerie-gateway
#   Stage 2: static binary into a minimal Chainguard image
#
# Exposes:
#   4000 — HTTP (REST + GraphQL + gRPC-JSON, path-routed)
#
# Build:   podman build -t aerie-gateway -f Containerfile .
# Run:     podman run -p 4000:4000 aerie-gateway

# --- Stage 1: Build (Zig) ---
FROM cgr.dev/chainguard/wolfi-base:latest AS builder

RUN apk add --no-cache zig

WORKDIR /app
COPY . .
RUN zig build -Doptimize=ReleaseSafe \
    && cp zig-out/bin/aerie-gateway /app/aerie-gateway

# --- Stage 2: Runtime ---
FROM cgr.dev/chainguard/static:latest

COPY --from=builder /app/aerie-gateway /aerie-gateway

# HTTP (REST + GraphQL + gRPC-JSON)
EXPOSE 4000

ENTRYPOINT ["/aerie-gateway"]
