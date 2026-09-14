K9!
# SPDX-License-Identifier: MPL-2.0
# Yard-level component: passive collector (Zeek/Suricata)

let pedigree_schema = import "../k9/pedigree.ncl" in

let
  pedigree = pedigree_schema.K9Pedigree {
  metadata = {
    name = "aerie-passive-collector",
    version = "1.0.0-alpha",
    description = "Passive protocol forensics collector (listen-only)",
  },
  target = {
    os = 'Linux,
    requires_podman = true,
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

  collector = {
    engines = ["zeek", "suricata"],
    mode = "listen-only",
    outputs = ["structured-logs", "flow-metadata"],
    pipeline = [
      "collector -> normaliser -> verisim-temporal",
      "collector -> graph-enricher -> arango",
    ],
    notes = [
      "Passive collection must not inject or modify traffic.",
      "All logs are bitemporal (valid_time + tx_time).",
    ],
  },
}
