# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: bitemporal storage plan

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
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
  pedigree = component_pedigree,

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
