;; SPDX-License-Identifier: PMPL-1.0-or-later
;; PLAYBOOK.scm - Operational playbook for aerie

(playbook
  (operational-flows
    ("Policy-gated GraphQL requests")
    ("Realtime subscription streams with proofs")
    ("Bitemporal audit retrieval"))

  (guardrails
    ("Always regenerate specs outputs via K9")
    ("Never bypass entitlement checks")
    ("Record tx_time for all audit events")))
