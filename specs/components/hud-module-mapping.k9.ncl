# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: HUD widget to module mapping

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-hud-module-mapping",
    version = "1.0.0-alpha",
    description = "HUD widget mapping to OSI modules and entitlements",
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
      widget = "Hardware Health",
      osi_layers = ["L1", "L2"],
      module = "core.telemetry",
      data_sources = ["nic-telemetry", "sfp-telemetry"],
    },
    {
      widget = "Route Map",
      osi_layers = ["L3"],
      module = "forensics.routes",
      data_sources = ["bgp-updates", "mtr-paths", "geoip"],
    },
    {
      widget = "Port Heatmap",
      osi_layers = ["L4"],
      module = "forensics.routes",
      data_sources = ["flow-logs", "port-scan-results"],
    },
    {
      widget = "Header Stream",
      osi_layers = ["L7"],
      module = "audit.attested",
      data_sources = ["sni-headers", "user-agents"],
    },
  ],
}
