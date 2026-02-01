;; SPDX-License-Identifier: PMPL-1.0-or-later
;; STATE.scm - Project state for aerie

(state
  (metadata
    (version "0.1.1")
    (schema-version "1.0")
    (created "2026-02-01")
    (updated "2026-02-01")
    (project "aerie")
    (repo "hyperpolymath/aerie"))

  (project-context
    (name "Aerie")
    (tagline "Cyber-focused network diagnostic suite")
    (tech-stack ("svalinn" "vordr" "cerro-torre" "selur" "verisimdb" "vql" "arango" "dragonfly" "graphql" "rescript-tea" "cadre-tea-router" "a2ml")))

  (current-position
    (phase "spec-foundation")
    (overall-completion 30)
    (working-features
      ("K9 specs system"
       "Proof envelope spec"
       "GraphQL schema outline"
       "Policy gate and subscription auth flow"
       "Bitemporal storage plan"
       "Active probe / alerting HUD spec"
       "SmokePing retention + webhook thresholds"
       "Known limitations + guardrails"))))
