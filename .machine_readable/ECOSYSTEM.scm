;; SPDX-License-Identifier: PMPL-1.0-or-later
;; ECOSYSTEM.scm - Ecosystem position for aerie
;; Media-Type: application/vnd.ecosystem+scm

(ecosystem
  (version "1.0")
  (name "aerie")
  (type "security-diagnostics")
  (purpose "Cyber-focused network diagnostics with forensic-grade evidence")

  (position-in-ecosystem
    (category "security")
    (subcategory "network-forensics")
    (unique-value ("proof-enveloped telemetry" "policy-based module entitlements")))

  (related-projects
    ("svalinn" "vordr" "cerro-torre" "selur" "verisimdb" "a2ml" "k9-svc"))

  (what-this-is
    ("Network diagnostics platform"
     "Forensic-grade telemetry suite"
     "Policy-gated realtime dashboard"))

  (what-this-is-not
    ("Commodity speedtest clone"
     "Third-party telemetry collector")))
