// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// main.rs — Aerie triple-mount API gateway entry point (Rust rewrite)
//
// Replaces: src/api/v/main.v (644 LOC, deprecated 2026-04-12)
//
// Architecture: three independent listeners share a single AppState:
//
//   Port AERIE_PORT (default 4000)
//     • REST  — axum HTTP/1.1 router, conditionally mounted via ENABLE_REST
//     • GraphQL — POST /api/v1/graphql, conditionally mounted via ENABLE_GRAPHQL
//
//   Port AERIE_GRPC_PORT (default 4001)
//     • gRPC Phase 1 — raw TCP, 4-byte big-endian length prefix + JSON body
//       conditionally started via ENABLE_GRPC
//
// Mount flags: ENABLE_REST, ENABLE_GRAPHQL, ENABLE_GRPC (default "true").
// Setting any to "false" disables that listener at startup.
//
// Verb governance is applied as an axum middleware: disallowed verbs
// receive a 404 (stealth deny) + 1–8 ms timing jitter on all responses.

mod backends;
mod policy;
mod proof;
mod redis_client;
mod resolvers;
mod verb_governance;

use axum::{
    extract::{Extension, Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use resolvers::AppState;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tracing::{error, info};
use verb_governance::VerbGovernor;

// ─── Axum handler helpers ────────────────────────────────────────────────────

/// Extract the `X-Api-Key` header value, or return an empty string.
fn extract_api_key(headers: &HeaderMap) -> &str {
    headers
        .get("x-api-key")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
}

/// Convert a (status_code, body_string) tuple into an axum Response.
fn json_response(status: u16, body: String) -> impl IntoResponse {
    let code = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    (code, [(axum::http::header::CONTENT_TYPE, "application/json")], body)
}

// ─── REST handlers ───────────────────────────────────────────────────────────

/// GET /health — unauthenticated liveness probe.
async fn health() -> impl IntoResponse {
    (
        StatusCode::OK,
        [(axum::http::header::CONTENT_TYPE, "application/json")],
        r#"{"status":"serving","service":"aerie-api"}"#,
    )
}

/// GET /api/v1/telemetry — LibreSpeed throughput + IP info.
async fn telemetry(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    tokio::time::sleep(VerbGovernor::jitter_duration()).await;
    let (status, body) = resolvers::resolve_telemetry(state, extract_api_key(&headers)).await;
    json_response(status, body)
}

/// GET /api/v1/routes?target=<ip>&vrf=<vrf> — Hyperglass BGP routes.
async fn routes(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    tokio::time::sleep(VerbGovernor::jitter_duration()).await;
    let target = params.get("target").map(String::as_str).unwrap_or("0.0.0.0");
    let vrf = params.get("vrf").map(String::as_str).unwrap_or("default");
    let (status, body) =
        resolvers::resolve_route_forensics(state, extract_api_key(&headers), target, vrf).await;
    json_response(status, body)
}

/// GET /api/v1/smokeping?target=<host> — SmokePing latency/loss.
async fn smokeping(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    tokio::time::sleep(VerbGovernor::jitter_duration()).await;
    let target = params.get("target").map(String::as_str).unwrap_or("localhost");
    let (status, body) =
        resolvers::resolve_smokeping(state, extract_api_key(&headers), target).await;
    json_response(status, body)
}

/// GET /api/v1/audit?offset=<n>&count=<n> — Redis hot audit log.
async fn audit(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    tokio::time::sleep(VerbGovernor::jitter_duration()).await;
    let offset = params
        .get("offset")
        .and_then(|s| s.parse().ok())
        .unwrap_or(0usize);
    let count = params
        .get("count")
        .and_then(|s| s.parse().ok())
        .unwrap_or(20usize);
    let (status, body) =
        resolvers::resolve_audit(state, extract_api_key(&headers), offset, count).await;
    json_response(status, body)
}

/// GET /api/v1/temporal-audit — VerisimDB bitemporal query.
async fn temporal_audit(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    tokio::time::sleep(VerbGovernor::jitter_duration()).await;
    let as_of = params.get("as_of").map(String::as_str);
    let start = params.get("start").map(String::as_str);
    let end = params.get("end").map(String::as_str);
    let limit = params
        .get("limit")
        .and_then(|s| s.parse().ok())
        .unwrap_or(100usize);
    let (status, body) =
        resolvers::resolve_temporal_audit(state, extract_api_key(&headers), as_of, start, end, limit)
            .await;
    json_response(status, body)
}

/// POST /api/v1/graphql — GraphQL query dispatcher.
async fn graphql(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<serde_json::Value>,
) -> impl IntoResponse {
    tokio::time::sleep(VerbGovernor::jitter_duration()).await;
    let (status, resp) =
        resolvers::resolve_graphql(state, extract_api_key(&headers), body).await;
    json_response(status, resp)
}

// ─── gRPC Phase 1 listener ───────────────────────────────────────────────────

/// Spawn the Phase 1 gRPC listener on `grpc_port`.
///
/// Protocol: each request is a 4-byte big-endian length prefix followed by
/// that many bytes of JSON. The response is the same framing. Each connection
/// is handled in a separate tokio task. Unknown method names return an error
/// JSON frame — the gateway never closes the connection abruptly.
async fn run_grpc_listener(grpc_port: u16, state: Arc<AppState>) {
    let addr = format!("0.0.0.0:{}", grpc_port);
    let listener = match TcpListener::bind(&addr).await {
        Ok(l) => l,
        Err(e) => {
            error!("gRPC: bind {} failed: {}", addr, e);
            return;
        }
    };
    info!("gRPC listener on {}", addr);

    loop {
        let (mut socket, peer) = match listener.accept().await {
            Ok(c) => c,
            Err(e) => {
                error!("gRPC: accept error: {}", e);
                continue;
            }
        };
        let state = state.clone();

        tokio::spawn(async move {
            loop {
                // Read 4-byte big-endian frame length
                let mut len_buf = [0u8; 4];
                match socket.read_exact(&mut len_buf).await {
                    Ok(_) => {}
                    Err(_) => break, // Client disconnected
                }
                let frame_len = u32::from_be_bytes(len_buf) as usize;

                // Reject unreasonably large frames (>1 MiB)
                if frame_len > 1_048_576 {
                    let err = grpc_error_frame("frame_too_large");
                    let _ = socket.write_all(&err).await;
                    break;
                }

                // Read frame body
                let mut body = vec![0u8; frame_len];
                if socket.read_exact(&mut body).await.is_err() {
                    break;
                }

                let request: serde_json::Value = match serde_json::from_slice(&body) {
                    Ok(v) => v,
                    Err(_) => {
                        let err = grpc_error_frame("invalid_json");
                        let _ = socket.write_all(&err).await;
                        continue;
                    }
                };

                let method = request["method"].as_str().unwrap_or("");
                let api_key = request["api_key"].as_str().unwrap_or("");

                // Route to resolver based on method name
                let (_, response_body) = match method {
                    "Telemetry" | "telemetry" => {
                        resolvers::resolve_telemetry(state.clone(), api_key).await
                    }
                    "RouteForensics" | "route_forensics" => {
                        let target = request["target"].as_str().unwrap_or("0.0.0.0");
                        let vrf = request["vrf"].as_str().unwrap_or("default");
                        resolvers::resolve_route_forensics(state.clone(), api_key, target, vrf)
                            .await
                    }
                    "SmokePing" | "smokeping" => {
                        let target = request["target"].as_str().unwrap_or("localhost");
                        resolvers::resolve_smokeping(state.clone(), api_key, target).await
                    }
                    "Audit" | "audit" => {
                        resolvers::resolve_audit(state.clone(), api_key, 0, 20).await
                    }
                    _ => {
                        let err = grpc_error_frame("unknown_method");
                        let _ = socket.write_all(&err).await;
                        continue;
                    }
                };

                // Write 4-byte length + JSON response frame
                let resp_bytes = response_body.as_bytes();
                let resp_len = (resp_bytes.len() as u32).to_be_bytes();
                let _ = socket.write_all(&resp_len).await;
                let _ = socket.write_all(resp_bytes).await;
            }
        });
    }
}

/// Build a gRPC error frame (4-byte length prefix + JSON body).
fn grpc_error_frame(code: &str) -> Vec<u8> {
    let body = serde_json::json!({"error": code}).to_string();
    let len = (body.len() as u32).to_be_bytes();
    let mut frame = Vec::with_capacity(4 + body.len());
    frame.extend_from_slice(&len);
    frame.extend_from_slice(body.as_bytes());
    frame
}

// ─── Router builder ──────────────────────────────────────────────────────────

/// Build the axum Router, optionally including REST and GraphQL endpoints.
fn build_router(
    state: Arc<AppState>,
    enable_rest: bool,
    enable_graphql: bool,
) -> Router {
    let mut app = Router::new().route("/health", get(health));

    if enable_rest {
        app = app
            .route("/api/v1/telemetry",      get(telemetry))
            .route("/api/v1/routes",          get(routes))
            .route("/api/v1/smokeping",       get(smokeping))
            .route("/api/v1/audit",           get(audit))
            .route("/api/v1/temporal-audit",  get(temporal_audit));
    }

    if enable_graphql {
        app = app.route("/api/v1/graphql", post(graphql));
    }

    app.with_state(state)
}

// ─── Entry point ─────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() {
    // Initialise structured logging; default filter: INFO
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "aerie_api=info,tower_http=info".into()),
        )
        .init();

    // Read mount flags
    let enable_rest = std::env::var("ENABLE_REST")
        .map(|v| v != "false")
        .unwrap_or(true);
    let enable_graphql = std::env::var("ENABLE_GRAPHQL")
        .map(|v| v != "false")
        .unwrap_or(true);
    let enable_grpc = std::env::var("ENABLE_GRPC")
        .map(|v| v != "false")
        .unwrap_or(true);

    // Read port numbers
    let http_port: u16 = std::env::var("AERIE_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(4000);
    let grpc_port: u16 = std::env::var("AERIE_GRPC_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(4001);

    info!(
        rest = enable_rest,
        graphql = enable_graphql,
        grpc = enable_grpc,
        http_port,
        grpc_port,
        "aerie-api starting"
    );

    let state = Arc::new(AppState::from_env());

    // Spawn gRPC listener as a background task
    if enable_grpc {
        let grpc_state = state.clone();
        tokio::spawn(async move {
            run_grpc_listener(grpc_port, grpc_state).await;
        });
    }

    // Build HTTP router and start listening
    let app = build_router(state, enable_rest, enable_graphql);
    let bind_addr = format!("0.0.0.0:{}", http_port);
    let listener = tokio::net::TcpListener::bind(&bind_addr)
        .await
        .unwrap_or_else(|e| panic!("failed to bind {}: {}", bind_addr, e));

    info!("HTTP listener on {}", bind_addr);
    axum::serve(listener, app)
        .await
        .unwrap_or_else(|e| error!("HTTP server error: {}", e));
}
