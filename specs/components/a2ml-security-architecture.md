# A2ML-Driven Security Architecture

This document describes the high-level architecture and philosophy for managing critical security infrastructure within the Aerie project, leveraging A2ML as a single source of truth.

### Key Features
| Component                 | Implementation                            | Automation                        |
|---------------------------|-------------------------------------------|-----------------------------------|
| **DNS + Trustfile**       | Pure A2ML (single file)                   | GitBot-Fleet hashing/diffing      |
| **Formal Verification**   | LEAN4 proofs for all critical sections    | CI/CD re-proves on push           |
| **Integrity Checks**      | SHA3-512 + SHAKE256 + ZoneMD              | Auto-updated by GitBot-Fleet      |
| **CI/CD**                 | GitHub Actions + GitBot-Fleet hooks       | Blocks merges on failed checks    |
| **Hypatia Scans**         | DNS, Crypto, PHP                          | Daily/weekly/on-push              |
| **Transparency Log**      | RFC 9162 + LEAN4-proven continuity        | Auto-appended on push             |
| **Consent-Aware HTTP**    | CAdRE + LEAN4 proof                       | Validated by GitBot-Fleet         |
| **PHP Hardening**         | PHP-Aegis + Sanctify-PHP + Hypatia scans  | Scanned on every commit           |
| **PQ Crypto**             | Ed448+Dilithium5 + SPHINCS+ fallback      | Key rotation on compromise        |
| **Capability Gateway**    | OCAP-style + LEAN4 proof                  | Validated pre-deploy              |

### How It Works
1.  **Single Source of Truth**:
    *   All config (DNS, Trustfile, CI/CD, policies) in **one A2ML file**.
    *   **No split brains**: Changes to DNS or crypto auto-update proofs and hashes.

2.  **Formal Guarantees**:
    *   **LEAN4** proves correctness of DNS, TLS, HTTP, and PHP rules.
    *   **Hypatia** scans for misconfigurations or drifts.
    *   **GitBot-Fleet** enforces integrity and auto-fixes hashes.

3.  **Automated Workflow**:
    *   **Pre-commit**: GitBot-Fleet validates A2ML and LEAN4 proofs.
    *   **Post-merge**: Auto-updates hashes, transparency log, and re-runs Hypatia.
    *   **On push**: CI/CD re-proves all theorems and blocks on failures.

4.  **Self-Healing**:
    *   If a DNS record changes, GitBot-Fleet:
        1.  Updates `zonemd` and integrity hashes.
        2.  Triggers LEAN4 to re-prove DNS correctness.
        3.  Appends to transparency log.

5.  **Zero Trust for Deploys**:
    *   Cloudflare/CAdRE/PHP **only accept changes** if:
        *   A2ML is valid.
        *   LEAN4 proofs pass.
        *   Hypatia scans pass.
        *   Signatures are valid.

### Extending This
To add a new service (e.g., `api.example.com`):
1.  Add the DNS record to `records`.
2.  Add a LEAN4 proof in `LEAN4_PROOFS` (e.g., `DNS.API.lean`).
3.  Update `ci_cd.jobs` to include the new proof in tests.
GitBot-Fleet and Hypatia will **auto-validate** everything else.

**Note**: A `sample DNS.API.lean` proof template for new services, or a `debugging guide` for Hypatia/LEAN4 integration can be provided if needed, once foundational A2ML content is in place.