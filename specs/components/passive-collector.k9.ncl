# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: passive collector (Zeek/Suricata)

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
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
  pedigree = component_pedigree,

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
