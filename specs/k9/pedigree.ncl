# SPDX-License-Identifier: AGPL-3.0-or-later
# Copied from k9-svc/pedigree.ncl for local Yard-level components.
# Keep in sync with /var/mnt/eclipse/repos/k9-svc/pedigree.ncl

let SecurityLevel = [| 'Kennel, 'Yard, 'Hunt |] in
let Architecture = [| 'Linux, 'Minix, 'MacOS, 'Android, 'PC, 'ASIC, 'Unknown |] in

{
  Metadata = {
    name | String,
    version | String | default = "1.0.0-alpha",
    breed | String | default = "application/vnd.k9+nickel",
    magic_number | String | default = "K9!",
    description | String | optional,
  },

  Target = {
    os | Architecture,
    is_edge | Bool | default = false,
    requires_podman | Bool | default = true,
    min_memory_mb | Number | default = 256,
  },

  Security = {
    trust_level | SecurityLevel | default = 'Yard,
    allow_network | Bool | default = false,
    allow_filesystem_write | Bool | default = false,
    allow_subprocess | Bool | default = false,
    signature | String | optional,
  },

  Validation = {
    checksum | String,
    pedigree_version | String | default = "1.0.0",
    hunt_authorized | Bool | default = false,
  },

  Recipes = {
    install | String | default = "just install",
    validate | String | default = "just validate",
    deploy | String | default = "just deploy",
    migrate | String | default = "just migrate",
  },

  K9Pedigree = {
    metadata | Metadata,
    target | Target,
    security | Security,
    validation | Validation,
    recipes | Recipes,
  },
}
