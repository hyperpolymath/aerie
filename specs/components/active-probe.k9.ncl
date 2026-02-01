# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: Active protocol probe stack + dashboard staging

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-active-probe",
    version = "1.0.0-alpha",
    description = "Active OSI prober suite connected to the Forensics HUD",
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

  active_probe = {
    purpose = "Inject deliberate probes so the HUD contrasts passive listening with reachable endpoints.",
    engines = [
      {
        name = "hyperglass",
        role = "BGP/traceroute forensic (MTR, BGP table lookups, ASN path verification)",
        targets = ["upstream peers", "Cloudflare peering points", "multi-region SAP"],
      },
      {
        name = "smokeping",
        role = "Latency/ping persistence",
        profile = "span across 24h/7d/30d windows to highlight jitter drift",
      },
      {
        name = "librespeed",
        role = "Zero-telemetry speed engine for upload/download/jitter",
        delivery = "Self-hosted via Dashy/Heimdall widget without CDN injection",
      },
      {
        name = "openspeedtest",
        role = "Optional secondary telemetry for browser fallback + telemetry cross-check",
      },
    ],
    dashboard = {
      host = "Dashy (preferred) or Heimdall",
      theme = "Midnight Security (dark gradients + neon lattice)",
      modules = [
        "Header stream (SNI/user-agent ticker)",
        "Path map (GeoIP hops with red flash on anomalies)",
        "Port heatmap (65k grid or trimmed set)",
        "Health bar (passive vs probe status per layer)",
      ],
    },
    security = {
      hardening = [
        "Centralise probes behind Cloudflare WAF + API Shield",
        "Expose only authenticated dashboards (mTLS, short-lived certs)",
        "Route data through Dashy/Heimdall with policy gating to avoid 'probe poisoning'",
      ],
    },
    alerting = {
      integration = ["Webhook", "ntfy", "Svalinn policy hooks"],
      conditions = [
        "Probe jitter > 5% for 3 consecutive SmokePing intervals",
        "Unexpected ASN hop (geo mismatch) during Hyperglass run",
        "LibreSpeed jitter > 10 ms while throughput remains steady",
      ],
    },
  },
}
