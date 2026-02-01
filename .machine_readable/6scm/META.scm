;; SPDX-License-Identifier: PMPL-1.0-or-later
;; META.scm - Meta-level information for aerie
;; Media-Type: application/meta+scheme

(meta
  (architecture-decisions
    ("Policy-based entitlements enforced at GraphQL gateway")
    ("Proof envelope required on all responses")
    ("Bitemporal audit via Verisim temporal modality"))

  (development-practices
    (code-style ("AsciiDoc for specs" "Oxford British English"))
    (security
      (principle "Defense in depth")
      (principle "Fail-closed entitlement checks")
      (principle "Proofs on all responses"))
    (testing ("Spec manifest checksum guard"))
    (versioning "SemVer")
    (documentation "AsciiDoc")
    (branching "main for stable"))

  (design-rationale
    ("Shift from speedtests to forensic-grade diagnostics")
    ("Federated data plane with verifiable proofs")))
