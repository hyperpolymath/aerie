K9!
# SPDX-License-Identifier: MPL-2.0
# Yard-level component: proof envelope format (light + full)

let pedigree_schema = import "../k9/pedigree.ncl" in

let
  pedigree = pedigree_schema.K9Pedigree {
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
  pedigree = pedigree,

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
      includes = ["result_hash", "policy_hash", "query_id", "issued_at", "signature", "a2ml_attestation", "vcl_proof"],
      suitable_for = ["audit", "forensics"],
    },
  },
}
