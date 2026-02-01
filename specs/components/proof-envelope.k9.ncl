# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: proof envelope format (light + full)

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-proof-envelope",
    version = "1.0.0-alpha",
    description = "Proof envelope for all responses (light/full)",
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

  proof_envelope = {
    required_on_all_results = true,
    tiers = ["light", "full"],

    fields = {
      result_hash = "sha256",
      policy_hash = "sha256",
      query_id = "uuid",
      issued_at = "rfc3339",
      proof_type = "light|full",
      signature = "ed25519",
    },

    light = {
      includes = ["result_hash", "policy_hash", "query_id", "issued_at", "signature"],
      suitable_for = ["realtime", "subscription"],
    },

    full = {
      includes = ["result_hash", "policy_hash", "query_id", "issued_at", "signature", "a2ml_attestation", "vql_proof"],
      suitable_for = ["audit", "forensics"],
    },
  },
}
