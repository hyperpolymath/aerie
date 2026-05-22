// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// types.zig — Shared domain types for the Aerie gateway.
//
// Mirrors the struct definitions previously scattered across:
//   policy.v        → AccessLevel, PolicyDecision, AuditEvent
//   proof.v         → ProofEnvelope
//   librespeed_client.v → TelemetrySample, TelemetryPayload
//   hyperglass_client.v → RouteHop, RouteForensicsPayload
//   smokeping_client.v  → SmokePingSample, SmokeChartPoint, SmokePingPayload
//
// All types are plain value structs; no heap allocation here.

/// ProtocolConfig holds the enabled/disabled state for each protocol.
/// Read once at startup from environment variables — immutable thereafter.
pub const ProtocolConfig = struct {
    rest_enabled:    bool,
    graphql_enabled: bool,
    grpc_enabled:    bool,
};

/// AccessLevel categorises the caller's authentication status.
pub const AccessLevel = enum {
    anonymous,    // No API key provided
    authenticated, // Valid API key format
    invalid,      // Malformed API key
};

/// PolicyDecision captures the result of evaluating a request against
/// the policy gate. Every decision is recorded in the Redis audit log.
pub const PolicyDecision = struct {
    allowed:      bool,
    access_level: AccessLevel,
    api_key:      [64]u8,  // Redacted key, null-terminated
    api_key_len:  usize,
    module_name:  [64]u8,
    module_len:   usize,
    timestamp:    [32]u8,  // RFC 3339
    timestamp_len: usize,
    reason:       [128]u8,
    reason_len:   usize,
};

/// AuditEvent represents a single entry in the Redis audit log.
/// Matches the protobuf AuditEvent message and the Idris2 ABI type.
pub const AuditEvent = struct {
    event_id:   [37]u8,  // UUID v4 string (36 chars + null)
    valid_time: [32]u8,  // RFC 3339
    tx_time:    [32]u8,
    severity:   [16]u8,
    message:    [256]u8,
    message_len: usize,
    tags:       [8][32]u8,  // Up to 8 tags, each up to 31 chars + null
    tag_count:  usize,
};

/// ProofEnvelope wraps every API response with a cryptographic hash
/// and metadata for auditability and tamper detection.
///
/// result_hash: SHA-256 hex digest of the JSON response body (64 hex chars)
/// policy_hash: SHA-256 hex digest of the policy rules applied
/// query_id:    UUID v4 identifying this specific request
/// issued_at:   RFC 3339 timestamp
/// proof_type:  "light" (hash-only, Phase 1) or "full" (signed, Phase 2+)
pub const ProofEnvelope = struct {
    result_hash: [65]u8,  // 64 hex + null
    policy_hash: [65]u8,
    query_id:    [37]u8,  // UUID v4: 36 chars + null
    issued_at:   [32]u8,
    proof_type:  [8]u8,
};

/// TelemetrySample represents a single network measurement from LibreSpeed.
pub const TelemetrySample = struct {
    timestamp:   [32]u8,
    latency_ms:  f64,
    jitter_ms:   f64,
    packet_loss: f64,
};

/// RouteHop represents a single hop in a BGP route path.
pub const RouteHop = struct {
    hop:    i32,
    ip:     [64]u8,
    ip_len: usize,
    asn:    [64]u8,
    asn_len: usize,
    rtt_ms: f64,
};

/// SmokePingSample represents a single measurement snapshot from SmokePing.
pub const SmokePingSample = struct {
    timestamp:  [32]u8,
    target:     [128]u8,
    target_len: usize,
    median_ms:  f64,
    loss_pct:   f64,
    min_ms:     f64,
    max_ms:     f64,
    stddev_ms:  f64,
};

/// SmokeChartPoint is a single point in a SmokePing smoke chart time series.
pub const SmokeChartPoint = struct {
    timestamp:  [32]u8,
    median_ms:  f64,
    loss_pct:   f64,
};

/// VerbDecision is the result of checking a request against verb rules.
pub const VerbDecision = struct {
    allowed:   bool,
    matched:   bool,
    rule_name: [64]u8,
    rule_len:  usize,
    verb:      [16]u8,
    verb_len:  usize,
    stealth:   bool,
};
