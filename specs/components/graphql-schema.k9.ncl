# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: GraphQL schema outline + module subscriptions

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-graphql-schema",
    version = "1.0.0-alpha",
    description = "GraphQL schema outline with module-scoped subscriptions",
  },
  target = {
    os = 'Linux,
    requires_podman = false,
  },
  security = {
    trust_level = 'Yard,
  },
  validation = {
    checksum = "sha256:placeholder",
  },
} in

{
  pedigree = component_pedigree,

  graphql = {
    proof_envelope_required = true,
    subscription_model = "granular-per-module",

    core_types = [
      "DateTime",
      "JSON",
      "ProofEnvelope",
      "ProofEnvelopeLight",
      "ProofEnvelopeFull",
      "TelemetrySample",
      "RouteHop",
      "AuditEvent",
      "TelemetryPayload",
      "RouteForensicsPayload",
      "AuditPayload",
    ],

    queries = [
      "telemetrySnapshot",
      "routeForensicsSnapshot",
      "auditSnapshot",
    ],

    subscriptions = [
      "telemetryStream",
      "routeForensicsStream",
      "auditAttestedStream",
    ],

    resolver_mapping = [
      {
        field = "telemetrySnapshot",
        vql = "slipstream temporal",
        proof = "light",
      },
      {
        field = "routeForensicsSnapshot",
        vql = "proved graph",
        proof = "full",
      },
      {
        field = "auditSnapshot",
        vql = "proved temporal+semantic",
        proof = "full",
      },
      {
        field = "telemetryStream",
        vql = "slipstream subscription",
        proof = "light",
      },
      {
        field = "routeForensicsStream",
        vql = "proved subscription",
        proof = "full",
      },
      {
        field = "auditAttestedStream",
        vql = "proved subscription",
        proof = "full",
      },
    ],

    notes = [
      "GraphQL is the user-facing API; VQL executes behind resolvers.",
      "Subscriptions are real-time via WebSockets/SSE (not RTSP).",
      "Slipstream path for realtime; full proofs for audit/forensics.",
    ],
  },
}
