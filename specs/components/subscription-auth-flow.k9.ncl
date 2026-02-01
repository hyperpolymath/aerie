# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: subscription auth handshake + proof flow

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-subscription-auth-flow",
    version = "1.0.0-alpha",
    description = "Subscription auth handshake and proof flow",
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

  flow = {
    steps = [
      "client-connect",
      "send-auth-headers",
      "policy-verify",
      "entitlement-check",
      "subscription-accept",
      "stream-events",
    ],
    headers = ["Authorization", "X-Entitlement-Policy", "X-Policy-Hash"],
    proof = {
      required_on_each_event = true,
      light_default = true,
      full_on_request = true,
    },
  },
}
