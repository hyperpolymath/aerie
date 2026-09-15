K9!
# SPDX-License-Identifier: MPL-2.0
# Yard-level component: bitemporal storage plan

let pedigree_schema = import "../k9/pedigree.ncl" in

let
  pedigree = pedigree_schema.K9Pedigree {
  metadata = {
    name = "aerie-bitemporal-store",
    version = "1.0.0-alpha",
    description = "Bitemporal storage layout (valid-time + tx-time)",
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

  bitemporal = {
    store = "verisim-temporal",
    fields = {
      valid_time = "time_when_event_occurs",
      tx_time = "time_when_recorded",
    },
    indexes = [
      "(hexad_id, valid_time)",
      "(hexad_id, tx_time)",
      "(policy_hash, tx_time)",
    ],
    notes = [
      "All audit events are stored with valid_time + tx_time.",
      "GraphQL proof envelopes must include tx_time reference.",
    ],
  },
}
