// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// policy.rs — Request policy evaluation for the Aerie API gateway
//
// Mirrors src/api/v/policy.v (135 LOC).
//
// Phase 1 policy: permissive — all well-formed requests are allowed.
// The policy gate validates X-Api-Key format (≥16 chars, alphanumeric
// + hyphen) and classifies callers into access tiers. All tiers are
// currently allowed; future phases will enforce per-tier rate limits
// and endpoint restrictions.
//
// Each decision is logged to the Redis audit trail via dual_log_audit.

use chrono::Utc;
use uuid::Uuid;

/// Access tier assigned by policy evaluation.
/// Higher tiers may access more endpoints (Phase 2+).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AccessLevel {
    /// API key absent or malformed — request denied
    Denied,
    /// Well-formed key with no special permissions
    Standard,
    /// Extended quota and additional endpoints
    Premium,
    /// Full administrative access
    Admin,
    /// Internal system-to-system calls (e.g. Hypatia)
    System,
}

/// Outcome of evaluating a single inbound request against the policy engine.
///
/// Phase 1: all non-Denied levels are treated identically (all allowed).
/// The `access_level` field is preserved in the audit log so that Phase 2
/// enforcement can be back-tested against real traffic.
#[derive(Debug, Clone, serde::Serialize)]
pub struct PolicyDecision {
    /// Whether the request is permitted to proceed
    pub allowed: bool,
    /// Tier classification of the caller
    pub access_level: AccessLevel,
    /// Human-readable reason, written to the audit log
    pub reason: String,
    /// Which policy module produced this decision (for tracing)
    pub module_name: String,
    /// UUID v4 correlation ID; echoed in the ProofEnvelope
    pub query_id: String,
}

/// Evaluate the policy for a single request.
///
/// `api_key` is taken from the `X-Api-Key` HTTP header (may be empty).
/// `module_name` is the resolver name (e.g. `"telemetry"`) for tracing.
///
/// Returns a `PolicyDecision` that callers must check before processing
/// the request. Never panics — all error paths return a Denied decision.
pub fn evaluate_policy(api_key: &str, module_name: &str) -> PolicyDecision {
    let query_id = Uuid::new_v4().to_string();

    // Validate key format: non-empty, ≥16 chars, alphanumeric + hyphen only.
    // An absent or malformed key is denied immediately.
    if api_key.is_empty() {
        return PolicyDecision {
            allowed: false,
            access_level: AccessLevel::Denied,
            reason: "X-Api-Key header is absent".to_string(),
            module_name: module_name.to_string(),
            query_id,
        };
    }

    if api_key.len() < 16 {
        return PolicyDecision {
            allowed: false,
            access_level: AccessLevel::Denied,
            reason: format!("X-Api-Key too short ({} chars; minimum 16)", api_key.len()),
            module_name: module_name.to_string(),
            query_id,
        };
    }

    if !api_key.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return PolicyDecision {
            allowed: false,
            access_level: AccessLevel::Denied,
            reason: "X-Api-Key contains disallowed characters (alphanumeric + hyphen only)"
                .to_string(),
            module_name: module_name.to_string(),
            query_id,
        };
    }

    // Phase 1: permissive — any valid key is granted Standard access.
    // Future phases will look up the key in VerisimDB to assign tiers.
    PolicyDecision {
        allowed: true,
        access_level: AccessLevel::Standard,
        reason: "Phase 1 permissive policy — valid key format".to_string(),
        module_name: module_name.to_string(),
        query_id,
    }
}

/// Serialise a PolicyDecision to a compact JSON string for the Redis
/// audit log. Any serialisation error returns a minimal fallback JSON
/// so the audit pipeline is never interrupted.
pub fn decision_to_audit_json(decision: &PolicyDecision) -> String {
    let now = Utc::now().to_rfc3339();
    let payload = serde_json::json!({
        "query_id":     decision.query_id,
        "allowed":      decision.allowed,
        "access_level": decision.access_level,
        "reason":       decision.reason,
        "module":       decision.module_name,
        "ts":           now,
    });
    serde_json::to_string(&payload)
        .unwrap_or_else(|_| r#"{"error":"audit_serialise_failed"}"#.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_key_is_denied() {
        let d = evaluate_policy("", "test");
        assert!(!d.allowed);
        assert_eq!(d.access_level, AccessLevel::Denied);
    }

    #[test]
    fn short_key_is_denied() {
        let d = evaluate_policy("tooshort", "test");
        assert!(!d.allowed);
        assert_eq!(d.access_level, AccessLevel::Denied);
    }

    #[test]
    fn invalid_chars_denied() {
        let d = evaluate_policy("key-with-bad-char!", "test");
        assert!(!d.allowed);
        assert_eq!(d.access_level, AccessLevel::Denied);
    }

    #[test]
    fn valid_key_allowed() {
        let d = evaluate_policy("valid-key-16-chars", "test");
        assert!(d.allowed);
        assert_eq!(d.access_level, AccessLevel::Standard);
    }

    #[test]
    fn query_id_is_uuid_v4_format() {
        let d = evaluate_policy("valid-key-16-chars", "test");
        // UUID v4: 8-4-4-4-12 hex groups, version nibble = '4'
        let parts: Vec<&str> = d.query_id.split('-').collect();
        assert_eq!(parts.len(), 5);
        assert_eq!(parts[2].chars().next(), Some('4'));
    }
}
