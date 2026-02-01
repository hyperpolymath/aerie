# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: GraphQL resolver policy gate

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-resolver-policy-gate",
    version = "1.0.0-alpha",
    description = "Policy-based entitlement gate for GraphQL resolvers",
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

  gate = {
    enforcement_point = "graphql-gateway",
    order = [
      "extract-entitlement-policy",
      "verify-policy-signature",
      "validate-policy-profile",
      "check-module-claims",
      "emit-proof-envelope",
    ],
    fail_closed = true,
    audit = {
      log_all_decisions = true,
      include_policy_hash = true,
    },
  },
}
