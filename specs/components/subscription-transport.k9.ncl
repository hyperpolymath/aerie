# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: subscription transport spec (WebSocket/SSE)

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-subscription-transport",
    version = "1.0.0-alpha",
    description = "Subscription transport spec for realtime module streams",
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

  transport = {
    realtime = "true",
    protocols = ["websocket", "sse"],
    auth = {
      required = true,
      headers = ["Authorization", "X-Entitlement-Policy", "X-Policy-Hash"],
    },
    proof_envelope = "required",
    reconnect = {
      backoff_ms = 500,
      max_backoff_ms = 5000,
      jitter = true,
    },
    events = {
      heartbeat_seconds = 15,
      max_batch_size = 100,
    },
  },
}
