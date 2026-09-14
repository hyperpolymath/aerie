K9!
# SPDX-License-Identifier: MPL-2.0
# Yard-level component: resolver policy gate implementation skeleton

let pedigree_schema = import "../k9/pedigree.ncl" in

let
  pedigree = pedigree_schema.K9Pedigree {
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
  pedigree = pedigree,

  skeleton = {
    notes = [
      "Fail-closed entitlement gate",
      "Proof envelope on all responses",
      "Audit log required",
    ],
  },
}
