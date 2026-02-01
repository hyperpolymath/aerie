# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: module entitlements + policy gates

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-policy-entitlements",
    version = "1.0.0-alpha",
    description = "Policy-based module entitlements (A2ML attested)",
  },
  target = {
    os = 'Linux,
    requires_podman = false,
  },
  security = {
    trust_level = 'Yard,
    allow_network = false,
    allow_filesystem_write = false,
    allow_subprocess = false,
  },
  validation = {
    checksum = "sha256:placeholder",
  },
} in

{
  pedigree = component_pedigree,

  sources = {
    a2ml = [
      "/var/mnt/eclipse/repos/a2ml/SPEC.adoc",
      "/var/mnt/eclipse/repos/a2ml/SPEC.a2ml",
    ],
    verisimdb = [
      "/var/mnt/eclipse/repos/verisimdb/docs/vql-type-system.adoc",
      "/var/mnt/eclipse/repos/verisimdb/docs/vql-architecture.adoc",
    ],
    svalinn = [
      "/var/mnt/eclipse/repos/svalinn/spec/schemas/gateway-run-request.v2.json",
    ],
    k9 = [
      "/var/mnt/eclipse/repos/k9-svc/SPEC.adoc",
    ],
  },

  entitlements = {
    policy_format = "a2ml-profile",
    policy_required = true,
    policy_enforced_at = "graphql-gateway",
    policy_hash_required = true,

    modules = [
      {
        id = "core.telemetry",
        name = "Core Telemetry",
        required_claims = ["telemetry:read"],
        proof_required = true,
      },
      {
        id = "forensics.routes",
        name = "Route Forensics",
        required_claims = ["forensics:read"],
        proof_required = true,
      },
      {
        id = "audit.attested",
        name = "Attested Audit",
        required_claims = ["audit:read"],
        proof_required = true,
      },
    ],
  },
}
