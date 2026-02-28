# SPDX-License-Identifier: PMPL-1.0-or-later
#
# Containerfile — Aerie Gateway (Triple-Mount API Server)
#
# Multi-stage build:
#   Stage 1: Build the V-lang gateway binary using Alpine + V compiler
#   Stage 2: Copy binary into a minimal Chainguard static image
#
# Exposes:
#   4000 — HTTP (REST + GraphQL)
#   4001 — gRPC (length-prefixed binary protocol)
#
# Build:   podman build -t aerie-gateway -f Containerfile .
# Run:     podman run -p 4000:4000 -p 4001:4001 aerie-gateway

# --- Stage 1: Build ---
FROM cgr.dev/chainguard/wolfi-base:latest AS builder

# Install build dependencies: V-lang compiler + C toolchain
RUN apk add --no-cache \
    gcc \
    glibc-dev \
    git \
    make \
    wget

# Install V-lang compiler
WORKDIR /opt
RUN git clone --depth 1 https://github.com/vlang/v.git && \
    cd v && \
    make && \
    ln -s /opt/v/v /usr/local/bin/v

# Copy gateway source code
WORKDIR /app
COPY src/api/v/ ./src/api/v/
COPY src/api/graphql/ ./src/api/graphql/
COPY src/api/proto/ ./src/api/proto/

# Build the gateway binary (statically linked for Chainguard static image)
RUN v -prod -cc gcc -cflags '-static' -o /app/aerie-gateway src/api/v/main.v

# --- Stage 2: Runtime ---
FROM cgr.dev/chainguard/static:latest

COPY --from=builder /app/aerie-gateway /aerie-gateway

# HTTP (REST + GraphQL) and gRPC ports
EXPOSE 4000
EXPOSE 4001

ENTRYPOINT ["/aerie-gateway"]
