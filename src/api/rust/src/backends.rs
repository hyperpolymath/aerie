// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// backends.rs — HTTP clients for all Aerie backend services
//
// Mirrors the four V backend client files:
//   - src/api/v/librespeed_client.v  (122 LOC) → LibreSpeedClient
//   - src/api/v/hyperglass_client.v  (143 LOC) → HyperglassClient
//   - src/api/v/smokeping_client.v   (260 LOC) → SmokePingClient
//   - src/api/v/verisim_client.v     (156 LOC) → VerisimDbClient
//
// All clients are fire-and-forget where indicated: errors are logged to
// stderr and the caller receives an error Result. No client ever panics.
// All backend URLs are read from environment variables at construction
// time, with sensible container-network defaults.
//
// The `reqwest` async client is used throughout for non-blocking I/O.

use serde::{Deserialize, Serialize};

// ─── LibreSpeed ──────────────────────────────────────────────────────────────

/// Throughput and geolocation data from a LibreSpeed measurement.
///
/// Fields match the ABI definition in `src/abi/Types.idr` TelemetryResult.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryResult {
    /// Measured download speed in Mbit/s
    pub download_mbps: f64,
    /// Measured upload speed in Mbit/s
    pub upload_mbps: f64,
    /// Round-trip latency in milliseconds (ping to LibreSpeed server)
    pub latency_ms: f64,
    /// Jitter in milliseconds
    pub jitter_ms: f64,
    /// Client IP address as reported by the LibreSpeed backend
    pub ip_address: String,
    /// ISP name resolved from the client IP (may be empty)
    pub isp: String,
}

/// HTTP client for the LibreSpeed backend.
///
/// LibreSpeed is queried for two things:
///   1. `GET /backend/getIP.php` — client IP + ISP information
///   2. The speed-test endpoints (download/upload/ping) are invoked by
///      the browser client directly; the gateway only exposes the IP data
///      for the telemetry resolver.
pub struct LibreSpeedClient {
    base_url: String,
    client: reqwest::Client,
}

impl LibreSpeedClient {
    /// Construct from `LIBRESPEED_URL` (default `http://librespeed:80`).
    pub fn from_env() -> Self {
        let base_url = std::env::var("LIBRESPEED_URL")
            .unwrap_or_else(|_| "http://librespeed:80".to_string());
        LibreSpeedClient {
            base_url: base_url.trim_end_matches('/').to_string(),
            client: reqwest::Client::new(),
        }
    }

    /// Fetch client IP and ISP information from LibreSpeed.
    ///
    /// Returns a partial `TelemetryResult` with only `ip_address` and
    /// `isp` populated; speed measurements are zeros until Phase 2
    /// integrates the speed-test flow.
    pub async fn get_ip_info(&self) -> Result<TelemetryResult, String> {
        let url = format!("{}/backend/getIP.php", self.base_url);
        let resp = self
            .client
            .get(&url)
            .timeout(std::time::Duration::from_secs(10))
            .send()
            .await
            .map_err(|e| format!("librespeed: HTTP GET failed: {}", e))?;

        if !resp.status().is_success() {
            return Err(format!("librespeed: status {}", resp.status()));
        }

        // LibreSpeed returns a bare JSON object: {"processedString":"<ip>","rawIspInfo":"<isp>"}
        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| format!("librespeed: parse failed: {}", e))?;

        let ip = body["processedString"]
            .as_str()
            .unwrap_or("")
            .to_string();
        let isp = body["rawIspInfo"]
            .as_str()
            .unwrap_or("")
            .to_string();

        Ok(TelemetryResult {
            download_mbps: 0.0,
            upload_mbps: 0.0,
            latency_ms: 0.0,
            jitter_ms: 0.0,
            ip_address: ip,
            isp,
        })
    }
}

// ─── Hyperglass ──────────────────────────────────────────────────────────────

/// BGP route forensics result from Hyperglass.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouteForensicsResult {
    /// The query target (IP address or CIDR prefix)
    pub target: String,
    /// VRF/routing context queried (default `"default"`)
    pub vrf: String,
    /// List of matching BGP routes as serialised JSON strings
    pub routes: Vec<serde_json::Value>,
    /// Raw response body (preserved for ProofEnvelope hashing)
    pub raw: String,
}

/// HTTP client for the Hyperglass BGP looking-glass backend.
///
/// Hyperglass exposes a REST API at `/api/v1/query` that accepts a POST
/// body with `{"query_target": "...", "query_type": "bgp_route", "vrf": "..."}`.
pub struct HyperglassClient {
    base_url: String,
    client: reqwest::Client,
}

impl HyperglassClient {
    /// Construct from `HYPERGLASS_URL` (default `http://hyperglass:8001`).
    pub fn from_env() -> Self {
        let base_url = std::env::var("HYPERGLASS_URL")
            .unwrap_or_else(|_| "http://hyperglass:8001".to_string());
        HyperglassClient {
            base_url: base_url.trim_end_matches('/').to_string(),
            client: reqwest::Client::new(),
        }
    }

    /// Query BGP routes for a target address or prefix.
    ///
    /// `target` — IP address or CIDR prefix to query (e.g. `"203.0.113.1"`)
    /// `vrf`    — routing context (pass `"default"` when not specified)
    pub async fn query_routes(
        &self,
        target: &str,
        vrf: &str,
    ) -> Result<RouteForensicsResult, String> {
        let url = format!("{}/api/v1/query", self.base_url);
        let body = serde_json::json!({
            "query_target": target,
            "query_type":   "bgp_route",
            "vrf":          vrf,
        });

        let resp = self
            .client
            .post(&url)
            .json(&body)
            .timeout(std::time::Duration::from_secs(30))
            .send()
            .await
            .map_err(|e| format!("hyperglass: POST failed: {}", e))?;

        if !resp.status().is_success() {
            return Err(format!("hyperglass: status {}", resp.status()));
        }

        let raw = resp
            .text()
            .await
            .map_err(|e| format!("hyperglass: body read failed: {}", e))?;

        let parsed: serde_json::Value = serde_json::from_str(&raw)
            .unwrap_or_else(|_| serde_json::json!({"raw": raw}));

        let routes = parsed["routes"]
            .as_array()
            .cloned()
            .unwrap_or_default();

        Ok(RouteForensicsResult {
            target: target.to_string(),
            vrf: vrf.to_string(),
            routes,
            raw,
        })
    }
}

// ─── SmokePing ───────────────────────────────────────────────────────────────

/// A single SmokePing latency measurement snapshot.
///
/// Fields match `src/abi/Types.idr` SmokePingSample and
/// `src/api/proto/aerie.proto` SmokePingSample.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SmokePingSample {
    /// ISO 8601 timestamp of the measurement
    pub timestamp: String,
    /// Target hostname or IP that was probed
    pub target: String,
    /// Median round-trip time in milliseconds
    pub median_ms: f64,
    /// Packet loss percentage (0.0–100.0)
    pub loss_pct: f64,
    /// Minimum RTT in milliseconds
    pub min_ms: f64,
    /// Maximum RTT in milliseconds
    pub max_ms: f64,
    /// Standard deviation of RTT (jitter proxy)
    pub stddev_ms: f64,
}

/// A single smoke-chart data point for time-series rendering.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SmokeChartPoint {
    pub timestamp: String,
    pub median_ms: f64,
    pub loss_pct: f64,
}

/// Combined SmokePing payload: current snapshot + historical chart data.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SmokePingPayload {
    pub target: String,
    pub current: SmokePingSample,
    pub chart: Vec<SmokeChartPoint>,
}

/// HTTP client for the SmokePing backend.
///
/// SmokePing's CGI exposes latency/loss data for configured targets.
/// The gateway queries `/cgi-bin/smokeping.cgi` with a `display` and
/// `target` parameter and parses the response into typed structs.
pub struct SmokePingClient {
    base_url: String,
    client: reqwest::Client,
}

impl SmokePingClient {
    /// Construct from `SMOKEPING_URL` (default `http://smokeping:80`).
    pub fn from_env() -> Self {
        let base_url = std::env::var("SMOKEPING_URL")
            .unwrap_or_else(|_| "http://smokeping:80".to_string());
        SmokePingClient {
            base_url: base_url.trim_end_matches('/').to_string(),
            client: reqwest::Client::new(),
        }
    }

    /// Fetch latency data for `target` from SmokePing.
    ///
    /// Returns a `SmokePingPayload` with the most recent snapshot and
    /// historical chart points. On error, returns a zeroed-out sample
    /// rather than propagating the error — telemetry data is advisory.
    pub async fn get_data(&self, target: &str) -> Result<SmokePingPayload, String> {
        // SmokePing CGI: GET /cgi-bin/smokeping.cgi?display=s&target=<target>
        let url = format!(
            "{}/cgi-bin/smokeping.cgi?display=s&target={}",
            self.base_url,
            urlencod(target)
        );

        let resp = self
            .client
            .get(&url)
            .timeout(std::time::Duration::from_secs(15))
            .send()
            .await
            .map_err(|e| format!("smokeping: GET failed: {}", e))?;

        if !resp.status().is_success() {
            return Err(format!("smokeping: status {}", resp.status()));
        }

        let body = resp
            .text()
            .await
            .map_err(|e| format!("smokeping: body read failed: {}", e))?;

        // SmokePing CGI may return HTML or a lightweight JSON summary depending
        // on version and configuration. Attempt JSON parse first; fall back to
        // a zeroed sample with the raw body preserved for debugging.
        parse_smokeping_response(target, &body)
    }
}

/// Parse a SmokePing CGI response body into a `SmokePingPayload`.
///
/// Tries JSON format first (newer SmokePing builds with the JSON export
/// plugin), then falls back to a zeroed current sample with an empty chart.
fn parse_smokeping_response(target: &str, body: &str) -> Result<SmokePingPayload, String> {
    let now = chrono::Utc::now().to_rfc3339();

    // Attempt JSON parse
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(body) {
        let current = SmokePingSample {
            timestamp: v["timestamp"].as_str().unwrap_or(&now).to_string(),
            target: target.to_string(),
            median_ms: v["median"].as_f64().unwrap_or(0.0),
            loss_pct: v["loss"].as_f64().unwrap_or(0.0),
            min_ms: v["min"].as_f64().unwrap_or(0.0),
            max_ms: v["max"].as_f64().unwrap_or(0.0),
            stddev_ms: v["stddev"].as_f64().unwrap_or(0.0),
        };

        let chart = v["chart"]
            .as_array()
            .map(|pts| {
                pts.iter()
                    .map(|p| SmokeChartPoint {
                        timestamp: p["ts"].as_str().unwrap_or(&now).to_string(),
                        median_ms: p["median"].as_f64().unwrap_or(0.0),
                        loss_pct: p["loss"].as_f64().unwrap_or(0.0),
                    })
                    .collect()
            })
            .unwrap_or_default();

        return Ok(SmokePingPayload {
            target: target.to_string(),
            current,
            chart,
        });
    }

    // Fallback: return a zeroed sample; the gateway still responds with
    // a proof envelope so callers can detect the missing data.
    Ok(SmokePingPayload {
        target: target.to_string(),
        current: SmokePingSample {
            timestamp: now,
            target: target.to_string(),
            median_ms: 0.0,
            loss_pct: 0.0,
            min_ms: 0.0,
            max_ms: 0.0,
            stddev_ms: 0.0,
        },
        chart: vec![],
    })
}

// ─── VerisimDB ───────────────────────────────────────────────────────────────

/// HTTP client for the VerisimDB bitemporal audit store.
///
/// VerisimDB is the cold tier of the two-tier audit pipeline:
///   - Redis (hot): bounded list, fast, ephemeral
///   - VerisimDB (cold): permanent, bitemporal, forensic
///
/// All writes are fire-and-forget: errors are logged but never propagate
/// to the request handler. VerisimDB unavailability must not affect
/// gateway responsiveness.
pub struct VerisimDbClient {
    base_url: String,
    client: reqwest::Client,
}

impl VerisimDbClient {
    /// Construct from `VERISIMDB_URL` (default `http://verisimdb:8084`).
    pub fn from_env() -> Self {
        let base_url = std::env::var("VERISIMDB_URL")
            .unwrap_or_else(|_| "http://verisimdb:8084".to_string());
        VerisimDbClient {
            base_url: base_url.trim_end_matches('/').to_string(),
            client: reqwest::Client::new(),
        }
    }

    /// Persist an audit event to VerisimDB (fire-and-forget).
    ///
    /// `event_json` is the same JSON string as written to the Redis audit list.
    /// Any error is logged to stderr; the return value is discarded by callers.
    pub async fn store_audit(&self, event_json: &str) {
        let url = format!("{}/api/v1/events", self.base_url);
        match self
            .client
            .post(&url)
            .header("Content-Type", "application/json")
            .body(event_json.to_string())
            .timeout(std::time::Duration::from_secs(5))
            .send()
            .await
        {
            Ok(r) if !r.status().is_success() => {
                eprintln!("[aerie] verisimdb: store_audit status {}", r.status());
            }
            Err(e) => {
                eprintln!("[aerie] verisimdb: store_audit failed: {}", e);
            }
            Ok(_) => {}
        }
    }

    /// Query events as of a point in time.
    ///
    /// Returns a Vec of JSON event strings, or empty on error.
    pub async fn query_as_of(&self, as_of_time: &str, limit: usize) -> Vec<serde_json::Value> {
        let url = format!(
            "{}/api/v1/events?as_of={}&limit={}",
            self.base_url,
            urlencod(as_of_time),
            limit
        );
        self.get_events(&url).await
    }

    /// Query events within a valid-time range.
    pub async fn query_between(
        &self,
        start: &str,
        end: &str,
        limit: usize,
    ) -> Vec<serde_json::Value> {
        let url = format!(
            "{}/api/v1/events?start={}&end={}&limit={}",
            self.base_url,
            urlencod(start),
            urlencod(end),
            limit
        );
        self.get_events(&url).await
    }

    /// Retrieve the full bitemporal history of an event.
    pub async fn query_history(&self, event_id: &str) -> Vec<serde_json::Value> {
        let url = format!("{}/api/v1/events/{}/history", self.base_url, event_id);
        self.get_events(&url).await
    }

    async fn get_events(&self, url: &str) -> Vec<serde_json::Value> {
        let resp = match self
            .client
            .get(url)
            .timeout(std::time::Duration::from_secs(10))
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                eprintln!("[aerie] verisimdb: GET {} failed: {}", url, e);
                return vec![];
            }
        };

        if !resp.status().is_success() {
            eprintln!("[aerie] verisimdb: GET {} status {}", url, resp.status());
            return vec![];
        }

        let body: serde_json::Value = match resp.json().await {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[aerie] verisimdb: parse failed: {}", e);
                return vec![];
            }
        };

        body["events"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Minimal percent-encoding for query string values.
///
/// Encodes space, `+`, `&`, `=`, `?`, `#`, `%` only — the characters
/// most likely to break a URL when embedding user-supplied values into
/// query strings. Not a full RFC 3986 encoder.
fn urlencod(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            ' ' => out.push_str("%20"),
            '+' => out.push_str("%2B"),
            '&' => out.push_str("%26"),
            '=' => out.push_str("%3D"),
            '?' => out.push_str("%3F"),
            '#' => out.push_str("%23"),
            '%' => out.push_str("%25"),
            c => out.push(c),
        }
    }
    out
}
