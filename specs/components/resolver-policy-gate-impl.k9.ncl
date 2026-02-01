# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: resolver policy gate implementation skeleton

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-resolver-policy-gate-impl",
    version = "1.0.0-alpha",
    description = "Implementation skeleton for resolver policy gate",
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

  skeleton = {
    notes = [
      "Fail-closed entitlement gate",
      "Proof envelope on all responses",
      "Audit log required",
    ],
  },
}
