// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// resolvers.rs — Request handlers for Aerie REST and GraphQL endpoints
//
// Mirrors src/api/v/resolvers.v (289 LOC).
//
// Each resolver:
//   1. Evaluates the request policy (evaluate_policy)
//   2. Checks the Redis hot cache (GET); returns cached data if fresh
//   3. Calls the appropriate backend(s) for fresh data
//   4. Logs the policy decision to Redis (log_audit) + VerisimDB (store_audit)
//   5. Wraps the response in a ProofEnvelope (wrap_with_proof)
//   6. Stores the wrapped response in Redis (SET with TTL)
//   7. Returns the envelope JSON
//
// Resolvers are called from axum route handlers in main.rs.

use std::sync::Arc;
use tokio::sync::Mutex;

use crate::backends::{
    HyperglassClient, LibreSpeedClient, SmokePingClient, VerisimDbClient,
};
use crate::policy::{decision_to_audit_json, evaluate_policy};
use crate::proof::wrap_with_proof;
use crate::redis_client::RedisClient;

/// All resolver dependencies bundled into a single shared state.
///
/// Wrapped in `Arc<AppState>` and injected into axum via `Extension`.
pub struct AppState {
    pub redis: Arc<Mutex<RedisClient>>,
    pub librespeed: LibreSpeedClient,
    pub hyperglass: HyperglassClient,
    pub smokeping: SmokePingClient,
    pub verisimdb: VerisimDbClient,
}

impl AppState {
    /// Construct from environment variables. Panics if reqwest client
    /// construction fails (should never happen on a sane system).
    pub fn from_env() -> Self {
        AppState {
            redis: Arc::new(Mutex::new(RedisClient::from_env())),
            librespeed: LibreSpeedClient::from_env(),
            hyperglass: HyperglassClient::from_env(),
            smokeping: SmokePingClient::from_env(),
            verisimdb: VerisimDbClient::from_env(),
        }
    }
}

// ─── Cache helpers ────────────────────────────────────────────────────────────

const CACHE_TTL: u64 = 30; // seconds; matches V implementation

/// Attempt to return a cached response for `cache_key`.
/// Returns `Some(json)` on a cache hit, `None` on miss or Redis error.
async fn cache_get(redis: &Arc<Mutex<RedisClient>>, cache_key: &str) -> Option<String> {
    redis.lock().await.get(cache_key)
}

/// Store `value` in Redis under `cache_key` with the standard TTL.
async fn cache_set(redis: &Arc<Mutex<RedisClient>>, cache_key: &str, value: &str) {
    redis.lock().await.set(cache_key, value, CACHE_TTL);
}

/// Fire-and-forget: log policy decision to Redis + VerisimDB audit trail.
async fn dual_log(
    redis: &Arc<Mutex<RedisClient>>,
    verisimdb: &VerisimDbClient,
    audit_json: &str,
) {
    redis.lock().await.log_audit(audit_json);
    verisimdb.store_audit(audit_json).await;
}

// ─── Resolver: telemetry ─────────────────────────────────────────────────────

/// Resolve a telemetry request — fetches client IP/ISP from LibreSpeed.
///
/// GET /api/v1/telemetry
/// Header: X-Api-Key: <key>
pub async fn resolve_telemetry(state: Arc<AppState>, api_key: &str) -> (u16, String) {
    let decision = evaluate_policy(api_key, "telemetry");
    let audit_json = decision_to_audit_json(&decision);

    if !decision.allowed {
        dual_log(&state.redis, &state.verisimdb, &audit_json).await;
        return (401, denied_envelope(&decision.query_id));
    }

    let cache_key = "aerie:cache:telemetry";
    if let Some(cached) = cache_get(&state.redis, cache_key).await {
        dual_log(&state.redis, &state.verisimdb, &audit_json).await;
        return (200, cached);
    }

    let result = match state.librespeed.get_ip_info().await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[aerie] telemetry: librespeed error: {}", e);
            dual_log(&state.redis, &state.verisimdb, &audit_json).await;
            return (502, error_envelope("librespeed_unavailable", &decision.query_id));
        }
    };

    let data = serde_json::to_value(&result).unwrap_or(serde_json::Value::Null);
    let envelope = wrap_with_proof(data, &audit_json, &decision.query_id);

    cache_set(&state.redis, cache_key, &envelope).await;
    dual_log(&state.redis, &state.verisimdb, &audit_json).await;
    (200, envelope)
}

// ─── Resolver: route forensics ───────────────────────────────────────────────

/// Resolve a BGP route forensics request via Hyperglass.
///
/// GET /api/v1/routes?target=<ip>&vrf=<vrf>
/// Header: X-Api-Key: <key>
pub async fn resolve_route_forensics(
    state: Arc<AppState>,
    api_key: &str,
    target: &str,
    vrf: &str,
) -> (u16, String) {
    let decision = evaluate_policy(api_key, "route_forensics");
    let audit_json = decision_to_audit_json(&decision);

    if !decision.allowed {
        dual_log(&state.redis, &state.verisimdb, &audit_json).await;
        return (401, denied_envelope(&decision.query_id));
    }

    // Cache key includes target + vrf so different queries get independent slots
    let cache_key = format!("aerie:cache:routes:{}:{}", target, vrf);
    if let Some(cached) = cache_get(&state.redis, &cache_key).await {
        dual_log(&state.redis, &state.verisimdb, &audit_json).await;
        return (200, cached);
    }

    let result = match state.hyperglass.query_routes(target, vrf).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[aerie] route_forensics: hyperglass error: {}", e);
            dual_log(&state.redis, &state.verisimdb, &audit_json).await;
            return (502, error_envelope("hyperglass_unavailable", &decision.query_id));
        }
    };

    let data = serde_json::to_value(&result).unwrap_or(serde_json::Value::Null);
    let envelope = wrap_with_proof(data, &audit_json, &decision.query_id);

    cache_set(&state.redis, &cache_key, &envelope).await;
    dual_log(&state.redis, &state.verisimdb, &audit_json).await;
    (200, envelope)
}

// ─── Resolver: smokeping ─────────────────────────────────────────────────────

/// Resolve a SmokePing latency/loss request.
///
/// GET /api/v1/smokeping?target=<host>
/// Header: X-Api-Key: <key>
pub async fn resolve_smokeping(
    state: Arc<AppState>,
    api_key: &str,
    target: &str,
) -> (u16, String) {
    let decision = evaluate_policy(api_key, "smokeping");
    let audit_json = decision_to_audit_json(&decision);

    if !decision.allowed {
        dual_log(&state.redis, &state.verisimdb, &audit_json).await;
        return (401, denied_envelope(&decision.query_id));
    }

    let cache_key = format!("aerie:cache:smokeping:{}", target);
    if let Some(cached) = cache_get(&state.redis, &cache_key).await {
        dual_log(&state.redis, &state.verisimdb, &audit_json).await;
        return (200, cached);
    }

    let payload = match state.smokeping.get_data(target).await {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[aerie] smokeping: error: {}", e);
            dual_log(&state.redis, &state.verisimdb, &audit_json).await;
            return (502, error_envelope("smokeping_unavailable", &decision.query_id));
        }
    };

    let data = serde_json::to_value(&payload).unwrap_or(serde_json::Value::Null);
    let envelope = wrap_with_proof(data, &audit_json, &decision.query_id);

    cache_set(&state.redis, &cache_key, &envelope).await;
    dual_log(&state.redis, &state.verisimdb, &audit_json).await;
    (200, envelope)
}

// ─── Resolver: audit ─────────────────────────────────────────────────────────

/// Resolve an audit log retrieval request — reads from Redis hot cache.
///
/// GET /api/v1/audit?offset=<n>&count=<n>
/// Header: X-Api-Key: <key>
pub async fn resolve_audit(
    state: Arc<AppState>,
    api_key: &str,
    offset: usize,
    count: usize,
) -> (u16, String) {
    let decision = evaluate_policy(api_key, "audit");
    let audit_json = decision_to_audit_json(&decision);

    if !decision.allowed {
        dual_log(&state.redis, &state.verisimdb, &audit_json).await;
        return (401, denied_envelope(&decision.query_id));
    }

    let entries = state
        .redis
        .lock()
        .await
        .lrange("aerie:audit", offset, count.min(100));

    // Capture length before moving entries into the JSON value
    let entries_count = entries.len();
    let data = serde_json::json!({
        "entries": entries,
        "offset":  offset,
        "count":   entries_count,
    });

    let envelope = wrap_with_proof(data, &audit_json, &decision.query_id);
    dual_log(&state.redis, &state.verisimdb, &audit_json).await;
    (200, envelope)
}

// ─── Resolver: temporal audit ────────────────────────────────────────────────

/// Resolve a bitemporal audit query against VerisimDB.
///
/// GET /api/v1/temporal-audit?as_of=<rfc3339>&start=<rfc3339>&end=<rfc3339>&limit=<n>
/// Header: X-Api-Key: <key>
///
/// If `as_of` is provided, runs a point-in-time query.
/// If `start` and `end` are provided, runs a range query.
/// If none are provided, returns the 100 most recent events (as_of = now).
pub async fn resolve_temporal_audit(
    state: Arc<AppState>,
    api_key: &str,
    as_of: Option<&str>,
    start: Option<&str>,
    end: Option<&str>,
    limit: usize,
) -> (u16, String) {
    let decision = evaluate_policy(api_key, "temporal_audit");
    let audit_json = decision_to_audit_json(&decision);

    if !decision.allowed {
        dual_log(&state.redis, &state.verisimdb, &audit_json).await;
        return (401, denied_envelope(&decision.query_id));
    }

    let effective_limit = limit.min(1000);

    let events = match (as_of, start, end) {
        (Some(t), _, _) => state.verisimdb.query_as_of(t, effective_limit).await,
        (None, Some(s), Some(e)) => {
            state.verisimdb.query_between(s, e, effective_limit).await
        }
        _ => {
            let now = chrono::Utc::now().to_rfc3339();
            state
                .verisimdb
                .query_as_of(&now, effective_limit)
                .await
        }
    };

    // Capture length before moving events into the JSON value
    let events_count = events.len();
    let data = serde_json::json!({
        "events": events,
        "count":  events_count,
    });
    let envelope = wrap_with_proof(data, &audit_json, &decision.query_id);
    dual_log(&state.redis, &state.verisimdb, &audit_json).await;
    (200, envelope)
}

// ─── Resolver: GraphQL ───────────────────────────────────────────────────────

/// Resolve a GraphQL query.
///
/// POST /api/v1/graphql
/// Header: X-Api-Key: <key>
/// Body: {"query": "...", "variables": {...}}
///
/// Phase 1: dispatches `telemetry`, `routes`, `smokeping` queries to the
/// appropriate resolver based on the root field name. Unknown queries
/// return an error in the standard GraphQL error envelope.
pub async fn resolve_graphql(
    state: Arc<AppState>,
    api_key: &str,
    body: serde_json::Value,
) -> (u16, String) {
    let decision = evaluate_policy(api_key, "graphql");
    let audit_json = decision_to_audit_json(&decision);

    if !decision.allowed {
        dual_log(&state.redis, &state.verisimdb, &audit_json).await;
        return (401, denied_envelope(&decision.query_id));
    }

    // Extract query string — required field
    let query = match body["query"].as_str() {
        Some(q) => q.trim().to_string(),
        None => {
            return (
                400,
                serde_json::json!({"errors": [{"message": "query field required"}]})
                    .to_string(),
            )
        }
    };

    // Rudimentary field extraction: look for the first root field name.
    // A proper GraphQL parser is Phase 2.
    let (status, result) = if query.contains("telemetry") {
        resolve_telemetry(state.clone(), api_key).await
    } else if query.contains("routes") {
        let vars = &body["variables"];
        let target = vars["target"].as_str().unwrap_or("0.0.0.0");
        let vrf = vars["vrf"].as_str().unwrap_or("default");
        resolve_route_forensics(state.clone(), api_key, target, vrf).await
    } else if query.contains("smokeping") {
        let vars = &body["variables"];
        let target = vars["target"].as_str().unwrap_or("localhost");
        resolve_smokeping(state.clone(), api_key, target).await
    } else {
        let err = serde_json::json!({
            "errors": [{"message": "unknown root field — supported: telemetry, routes, smokeping"}]
        });
        (400, err.to_string())
    };

    // Wrap successful results in a GraphQL data envelope
    if status == 200 {
        let inner: serde_json::Value = serde_json::from_str(&result)
            .unwrap_or(serde_json::Value::Null);
        let gql = serde_json::json!({"data": inner});
        dual_log(&state.redis, &state.verisimdb, &audit_json).await;
        (200, gql.to_string())
    } else {
        dual_log(&state.redis, &state.verisimdb, &audit_json).await;
        (status, result)
    }
}

// ─── Envelope helpers ─────────────────────────────────────────────────────────

fn denied_envelope(query_id: &str) -> String {
    serde_json::json!({
        "error":    "policy_denied",
        "query_id": query_id,
    })
    .to_string()
}

fn error_envelope(code: &str, query_id: &str) -> String {
    serde_json::json!({
        "error":    code,
        "query_id": query_id,
    })
    .to_string()
}
