# SPDX-License-Identifier: PMPL-1.0-or-later
# bgp-backbone-lab module manifest for FlatRacoon orchestrator

{
  name = "bgp-backbone-lab",
  version = "0.1.0",
  layer = 'network,
  description = "BGP backbone lab with containerlab topology for eBGP peering simulation using FRRouting",
  repo = "github.com/hyperpolymath/bgp-backbone-lab",
  requires = ["containerlab"],
  provides = ["bgp-peering", "backbone-routing", "route-reflection"],
  config_schema = "configs/schema.ncl",
  health_endpoint = null,
  metrics_endpoint = null,
  deployment_mode = "kubectl",
  namespace = "bgp-lab",
}
