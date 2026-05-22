# SPDX-License-Identifier: MPL-2.0
# Yard-level component: VCL mapping for GraphQL fields

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-vcl-mapping",
    version = "1.0.0-alpha",
    description = "VCL mapping for GraphQL queries/subscriptions",
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
      vcl = "FROM verisim:temporal WHERE metric = 'telemetry' LIMIT 1",
      proof = "light",
    },
    {
      graphql = "routeForensicsSnapshot",
      vcl = "FROM verisim:graph WHERE target = $target PROOF strict",
      proof = "full",
    },
    {
      graphql = "auditSnapshot",
      vcl = "FROM verisim:temporal WHERE kind = 'audit' PROOF strict",
      proof = "full",
    },
    {
      graphql = "telemetryStream",
      vcl = "SUBSCRIBE verisim:temporal WHERE metric = 'telemetry'",
      proof = "light",
    },
    {
      graphql = "routeForensicsStream",
      vcl = "SUBSCRIBE verisim:graph WHERE target = $target PROOF strict",
      proof = "full",
    },
    {
      graphql = "auditAttestedStream",
      vcl = "SUBSCRIBE verisim:temporal WHERE kind = 'audit' PROOF strict",
      proof = "full",
    },
  ],
}
