# SPDX-License-Identifier: PMPL-1.0-or-later
# Yard-level component: Alerting + temporal retention for CF-NDS telemetry

let pedigree = import "../k9/pedigree.ncl" in

let component_pedigree = pedigree.K9Pedigree {
  metadata = {
    name = "aerie-alerting-retention",
    version = "1.0.0-alpha",
    description = "Long-term telemetry retention and policy-driven alerting",
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

  telemetry = {
    primary_store = "SmokePing",
    retention = {
      default_days = 90,
      extended_days = 365,
      justification = "Bitemporal tracing of jitter + packet loss for forensic review",
    },
    backfill = "Arango/VQL references the same dataset via VerisimDB federation",
    policy = [
      "SmokePing probes write both valid_time (probe timestamp) and tx_time (ingest time)",
      "Time-series exports feed Grafana/Kibana for anomaly overlays",
      "Retention tiering demotes old data to compressed archives (Arrow-file + dedupe)",
    ],
  },

  alerting = {
    thresholds = [
      {
        name = "packet_loss",
        source = "SmokePing",
        trigger = "> 5% loss for 3 intervals",
        action = "Webhook/ntfy + Svalinn policy gate (can pause probes)",
      },
      {
        name = "jitter_spike",
        source = "LibreSpeed",
        trigger = "10 ms rolling average increase ≈ 20% over baseline",
        action = "Dashy visual pulse + escalate to cloud WAF team",
      },
    ],
    delivery = [
      "Webhook to orchestration alert bus (Slack, ntfy, enterprise pager)",
      "Policy-based gating (Svalinn) to squash noisy alerts during maintenance windows",
    ],
    observability = [
      "Dashy alert badge summarises unresolved items",
      "Audit log entry per alert stored in Verisim DB (immutable, Ed448-signed)",
    ],
  },
}
