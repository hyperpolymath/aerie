# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: VQL mapping for GraphQL fields

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-vql-mapping",
    version = "1.0.0-alpha",
    description = "VQL mapping for GraphQL queries/subscriptions",
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

  mapping = [
    {
      graphql = "telemetrySnapshot",
      vql = "FROM verisim:temporal WHERE metric = 'telemetry' LIMIT 1",
      proof = "light",
    },
    {
      graphql = "routeForensicsSnapshot",
      vql = "FROM verisim:graph WHERE target = $target PROOF strict",
      proof = "full",
    },
    {
      graphql = "auditSnapshot",
      vql = "FROM verisim:temporal WHERE kind = 'audit' PROOF strict",
      proof = "full",
    },
    {
      graphql = "telemetryStream",
      vql = "SUBSCRIBE verisim:temporal WHERE metric = 'telemetry'",
      proof = "light",
    },
    {
      graphql = "routeForensicsStream",
      vql = "SUBSCRIBE verisim:graph WHERE target = $target PROOF strict",
      proof = "full",
    },
    {
      graphql = "auditAttestedStream",
      vql = "SUBSCRIBE verisim:temporal WHERE kind = 'audit' PROOF strict",
      proof = "full",
    },
  ],
}
