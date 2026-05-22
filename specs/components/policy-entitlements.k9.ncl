# SPDX-License-Identifier: MPL-2.0
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
      "/var$REPOS_DIR/a2ml/SPEC.adoc",
      "/var$REPOS_DIR/a2ml/SPEC.a2ml",
    ],
    verisim = [
      "/var$REPOS_DIR/verisim/docs/vcl-type-system.adoc",
      "/var$REPOS_DIR/verisim/docs/vcl-architecture.adoc",
    ],
    svalinn = [
      "/var$REPOS_DIR/svalinn/spec/schemas/gateway-run-request.v2.json",
    ],
    k9 = [
      "/var$REPOS_DIR/k9-svc/SPEC.adoc",
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
