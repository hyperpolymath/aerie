// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// verb_governance.rs — HTTP verb whitelist with prefix trie and timing jitter
//
// Mirrors src/api/v/verb_governance.v (285 LOC).
//
// Security model:
//   - Each route prefix has an explicit allowlist of HTTP verbs.
//   - Requests with a disallowed verb receive a 404 (not 405): "stealth" mode
//     makes the gateway appear to be a static server with nothing at that path,
//     frustrating enumeration tools that rely on 405 to confirm route existence.
//   - A random 1–8 ms delay is injected on both allowed and disallowed responses
//     to defeat timing-based route discovery.
//
// Trie structure: VerbGovernor holds a sorted Vec of (prefix, allowed_verbs)
// pairs. Lookup walks from the most specific to the least specific match,
// which with a sorted Vec is O(n) but typically exits after 1–2 comparisons
// for well-configured routes. (A real prefix trie is future work.)

use rand::Rng;
use std::collections::HashMap;

/// A single node in the verb governance table.
///
/// `prefix` — URL path prefix (e.g. `"/api/v1/telemetry"`).
/// `allowed` — HTTP methods that are permitted at this prefix.
struct GovNode {
    prefix: String,
    allowed: Vec<String>,
}

/// Verdict returned by `VerbGovernor::check`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GovVerdict {
    /// Request is permitted to proceed
    Allow,
    /// Request should receive a 404 (stealth deny — never 405)
    StealthDeny,
}

/// HTTP verb whitelist with stealth-deny behaviour and timing jitter.
///
/// Initialise once at startup via `VerbGovernor::new()` and share via
/// `Arc<VerbGovernor>` across all request handlers.
pub struct VerbGovernor {
    /// Sorted by prefix length descending so the most specific match wins
    nodes: Vec<GovNode>,
}

impl VerbGovernor {
    /// Build the default Aerie verb governance table.
    ///
    /// REST routes: GET-only for telemetry, routes, smokeping, audit,
    ///   temporal-audit; POST for GraphQL; GET for health (no auth required).
    /// gRPC routes are governed separately by the raw TCP listener.
    pub fn new() -> Self {
        let table: &[(&str, &[&str])] = &[
            ("/health",                          &["GET", "HEAD"]),
            ("/api/v1/telemetry",                &["GET"]),
            ("/api/v1/graphql",                  &["POST"]),
            ("/api/v1/routes",                   &["GET"]),
            ("/api/v1/smokeping",                &["GET"]),
            ("/api/v1/audit",                    &["GET"]),
            ("/api/v1/temporal-audit",           &["GET"]),
        ];

        let mut nodes: Vec<GovNode> = table
            .iter()
            .map(|(prefix, methods)| GovNode {
                prefix: prefix.to_string(),
                allowed: methods.iter().map(|m| m.to_string()).collect(),
            })
            .collect();

        // Sort by descending prefix length so the longest (most specific) match wins
        nodes.sort_by(|a, b| b.prefix.len().cmp(&a.prefix.len()));

        VerbGovernor { nodes }
    }

    /// Check whether `method` is allowed for the request `path`.
    ///
    /// Matches by prefix (longest match first). Unknown paths are also
    /// stealth-denied — the gateway never reveals its route table to
    /// unauthenticated probes.
    ///
    /// The caller is responsible for applying the timing jitter via
    /// `VerbGovernor::jitter_delay()` regardless of verdict, to ensure
    /// timing does not distinguish Allow from StealthDeny.
    pub fn check(&self, method: &str, path: &str) -> GovVerdict {
        for node in &self.nodes {
            if path == node.prefix || path.starts_with(&format!("{}/", node.prefix)) {
                let method_upper = method.to_ascii_uppercase();
                if node.allowed.iter().any(|m| m == &method_upper) {
                    return GovVerdict::Allow;
                } else {
                    // Verb found but not allowed — stealth deny
                    return GovVerdict::StealthDeny;
                }
            }
        }
        // No matching prefix — stealth deny unknown routes
        GovVerdict::StealthDeny
    }

    /// Sleep for a uniformly random duration in [1, 8] milliseconds.
    ///
    /// Called on BOTH allowed and denied paths so that response timing
    /// is statistically indistinguishable between the two outcomes.
    /// Implemented synchronously here; callers in async context should
    /// call `tokio::time::sleep(jitter_duration())` instead.
    pub fn jitter_duration() -> std::time::Duration {
        let ms = rand::thread_rng().gen_range(1u64..=8);
        std::time::Duration::from_millis(ms)
    }
}

impl Default for VerbGovernor {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gov() -> VerbGovernor {
        VerbGovernor::new()
    }

    #[test]
    fn get_health_allowed() {
        assert_eq!(gov().check("GET", "/health"), GovVerdict::Allow);
    }

    #[test]
    fn post_health_denied() {
        // POST to /health is not in the allowlist → stealth deny
        assert_eq!(gov().check("POST", "/health"), GovVerdict::StealthDeny);
    }

    #[test]
    fn get_telemetry_allowed() {
        assert_eq!(gov().check("GET", "/api/v1/telemetry"), GovVerdict::Allow);
    }

    #[test]
    fn delete_telemetry_denied() {
        assert_eq!(gov().check("DELETE", "/api/v1/telemetry"), GovVerdict::StealthDeny);
    }

    #[test]
    fn post_graphql_allowed() {
        assert_eq!(gov().check("POST", "/api/v1/graphql"), GovVerdict::Allow);
    }

    #[test]
    fn get_graphql_denied() {
        // GraphQL is POST-only
        assert_eq!(gov().check("GET", "/api/v1/graphql"), GovVerdict::StealthDeny);
    }

    #[test]
    fn unknown_route_denied() {
        assert_eq!(gov().check("GET", "/api/v1/nonexistent"), GovVerdict::StealthDeny);
    }

    #[test]
    fn method_check_is_case_insensitive() {
        assert_eq!(gov().check("get", "/health"), GovVerdict::Allow);
        assert_eq!(gov().check("Get", "/health"), GovVerdict::Allow);
    }

    #[test]
    fn jitter_duration_in_range() {
        for _ in 0..100 {
            let d = VerbGovernor::jitter_duration();
            assert!(d.as_millis() >= 1 && d.as_millis() <= 8);
        }
    }
}
