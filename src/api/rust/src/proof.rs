// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// proof.rs — ProofEnvelope generation for Aerie API responses
//
// Mirrors src/api/v/proof.v (90 LOC).
//
// Every Aerie response is wrapped in a ProofEnvelope that commits the
// gateway to the exact bytes it served:
//
//   {
//     "data": <original response value>,
//     "proof": {
//       "result_hash":  "<sha256 of JSON-serialised data>",
//       "policy_hash":  "<sha256 of policy decision JSON>",
//       "query_id":     "<UUID v4 from PolicyDecision>",
//       "issued_at":    "<RFC 3339 timestamp>",
//       "proof_type":   "light",
//       "signature":    ""          ← Phase 2: Ed25519 over result_hash
//     }
//   }
//
// Phase 1 ("light" mode): hashes only, no cryptographic signature.
// The empty `signature` field is intentional — it is a placeholder for
// Phase 2 where the gateway signs responses with an Ed25519 key stored
// in a Stapeln secret.

use chrono::Utc;
use sha2::{Digest, Sha256};

/// The inner proof metadata block nested under the `"proof"` key.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ProofMeta {
    /// SHA-256 hex digest of the JSON-serialised response data
    pub result_hash: String,
    /// SHA-256 hex digest of the policy decision JSON
    pub policy_hash: String,
    /// UUID v4 from the PolicyDecision — correlates request ↔ audit log ↔ proof
    pub query_id: String,
    /// RFC 3339 timestamp at envelope creation time
    pub issued_at: String,
    /// Always "light" in Phase 1; "full" when Ed25519 signature is added
    pub proof_type: String,
    /// Ed25519 signature over result_hash (Phase 2). Empty string in Phase 1.
    pub signature: String,
}

/// Top-level envelope that wraps every Aerie API response.
///
/// Callers receive `data` (the actual payload) alongside the proof
/// metadata, enabling independent verification of what the gateway
/// served and under what policy.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ProofEnvelope {
    /// The original response payload — any JSON value
    pub data: serde_json::Value,
    /// Cryptographic commitment metadata
    pub proof: ProofMeta,
}

/// Wrap `data` in a ProofEnvelope.
///
/// `data` — the JSON value to wrap (already-serialised response body)
/// `policy_json` — the audit JSON from `decision_to_audit_json`
/// `query_id` — UUID v4 from the PolicyDecision for cross-correlation
///
/// Returns the fully-serialised envelope as a JSON string ready for
/// writing to the HTTP response body.
pub fn wrap_with_proof(
    data: serde_json::Value,
    policy_json: &str,
    query_id: &str,
) -> String {
    let result_hash = sha256_hex(&data.to_string());
    let policy_hash = sha256_hex(policy_json);
    let issued_at = Utc::now().to_rfc3339();

    let envelope = ProofEnvelope {
        data,
        proof: ProofMeta {
            result_hash,
            policy_hash,
            query_id: query_id.to_string(),
            issued_at,
            proof_type: "light".to_string(),
            signature: String::new(),
        },
    };

    serde_json::to_string(&envelope)
        .unwrap_or_else(|_| r#"{"error":"envelope_serialise_failed"}"#.to_string())
}

/// Compute the SHA-256 hex digest of a string.
fn sha256_hex(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    hex::encode(hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn envelope_has_all_fields() {
        let data = serde_json::json!({"status": "ok"});
        let json = wrap_with_proof(data, r#"{"allowed":true}"#, "test-query-id");
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(v["data"].is_object());
        assert!(v["proof"]["result_hash"].is_string());
        assert!(v["proof"]["policy_hash"].is_string());
        assert_eq!(v["proof"]["query_id"], "test-query-id");
        assert_eq!(v["proof"]["proof_type"], "light");
        assert_eq!(v["proof"]["signature"], "");
    }

    #[test]
    fn result_hash_is_sha256_of_data() {
        let data = serde_json::json!({"x": 1});
        let json = wrap_with_proof(data.clone(), "{}", "qid");
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        let expected = sha256_hex(&data.to_string());
        assert_eq!(v["proof"]["result_hash"], expected);
    }

    #[test]
    fn deterministic_hash_for_same_input() {
        let h1 = sha256_hex("hello aerie");
        let h2 = sha256_hex("hello aerie");
        assert_eq!(h1, h2);
        assert_eq!(h1.len(), 64); // 32 bytes → 64 hex chars
    }
}
