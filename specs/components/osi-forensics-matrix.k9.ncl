# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: OSI forensics matrix + HUD widgets

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-osi-forensics-matrix",
    version = "1.0.0-alpha",
    description = "OSI matrix for passive/active forensics and HUD widgets",
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

  matrix = [
    {
      layer = "L7 Application",
      passive = "Capture headers, DNS leaks, TLS SNI hostnames",
      active = "Banner grabbing, HTTP status checks, API fuzzing, cipher audits",
    },
    {
      layer = "L6 Presentation",
      passive = "Identify encoding types and cleartext patterns",
      active = "Protocol downgrade tests (TLS 1.0), encoding vulnerability checks",
    },
    {
      layer = "L5 Session",
      passive = "Track session durations, retransmits, keep-alives",
      active = "Simulate timeouts, validate token/session hijack resistance",
    },
    {
      layer = "L4 Transport",
      passive = "TCP/UDP flows, SYN/ACK/FIN patterns",
      active = "Port scans, MTU discovery, half-open limits",
    },
    {
      layer = "L3 Network",
      passive = "BGP monitoring, ASN path changes",
      active = "Ping/Traceroute/MTR, TTL OS fingerprinting",
    },
    {
      layer = "L2 Data Link",
      passive = "MAC OUI lookup, ARP table changes",
      active = "ARP scanning for hidden devices",
    },
    {
      layer = "L1 Physical",
      passive = "SNR, link speed, cable/SFP telemetry",
      active = "Path redundancy tests, electrical/optical error rates",
    }
  ],

  widgets = [
    {
      id = "l1-l2-health",
      name = "Hardware Health",
      description = "NIC throughput, error rates, SFP telemetry",
    },
    {
      id = "l3-route-map",
      name = "Route Map",
      description = "GeoIP hop map with anomaly highlighting",
    },
    {
      id = "l4-port-heatmap",
      name = "Port Heatmap",
      description = "Port activity grid (common ports or full map)",
    },
    {
      id = "l7-header-stream",
      name = "Header Stream",
      description = "User-Agents and Hostnames ticker",
    }
  ],
}
