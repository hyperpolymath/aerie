// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// policy.zig — Policy Gate Middleware
//
// Phase 1: Permissive gate — all requests are allowed. If the X-Api-Key
// header is present it is validated for format and logged. If absent the
// request proceeds but is marked "anonymous" in the audit log.
//
// Phase 2+ will add per-module entitlements.
//
// Replaces: policy.v

const std  = @import("std");
const t    = @import("types.zig");
const prf  = @import("proof.zig");

/// Validate API key format: minimum 16 characters, alphanumeric + hyphen.
fn isValidKeyFormat(key: []const u8) bool {
    if (key.len < 16) return false;
    for (key) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    }
    return true;
}

/// Redact an API key to "first8chars...". Result placed in `out`.
fn redactKey(key: []const u8, out: *[64]u8) usize {
    const prefix_len = @min(key.len, 8);
    @memcpy(out[0..prefix_len], key[0..prefix_len]);
    @memcpy(out[prefix_len..][0..3], "...");
    out[prefix_len + 3] = 0;
    return prefix_len + 3;
}

/// Copy `src` into the fixed-length field `dst`, null-terminating.
/// Returns the number of bytes written (excluding the null).
fn copyField(comptime N: usize, dst: *[N]u8, src: []const u8) usize {
    const n = @min(src.len, N - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
    return n;
}

/// Evaluate the policy gate for an incoming request.
///
/// Phase 1 behaviour: all requests allowed regardless of API key.
/// API keys are validated for format; missing keys are "anonymous".
/// Invalid-format keys are still allowed (permissive phase).
pub fn evaluatePolicy(api_key: []const u8, module_name: []const u8) t.PolicyDecision {
    var dec: t.PolicyDecision = std.mem.zeroes(t.PolicyDecision);
    dec.module_len  = copyField(64, &dec.module_name, module_name);

    var ts_buf: [32]u8 = undefined;
    prf.formatRfc3339(&ts_buf);
    dec.timestamp_len = copyField(32, &dec.timestamp, std.mem.sliceTo(&ts_buf, 0));

    if (api_key.len == 0) {
        dec.allowed      = true;
        dec.access_level = .anonymous;
        dec.api_key_len  = 0;
        dec.api_key[0]   = 0;
        dec.reason_len   = copyField(128, &dec.reason,
            "Phase 1 permissive: anonymous access allowed");
        return dec;
    }

    dec.api_key_len = redactKey(api_key, &dec.api_key);
    dec.allowed     = true;

    if (isValidKeyFormat(api_key)) {
        dec.access_level = .authenticated;
        dec.reason_len   = copyField(128, &dec.reason, "Valid API key authenticated");
    } else {
        dec.access_level = .invalid;
        dec.reason_len   = copyField(128, &dec.reason,
            "Phase 1 permissive: invalid key format but access allowed");
    }

    return dec;
}

/// Convert a PolicyDecision into an AuditEvent for the Redis audit log.
/// `query_id` is used as the event_id (mirrors decision_to_audit_event in policy.v).
pub fn decisionToAuditEvent(decision: t.PolicyDecision, query_id: []const u8) t.AuditEvent {
    var ev: t.AuditEvent = std.mem.zeroes(t.AuditEvent);

    // event_id — UUID supplied by caller (from proof envelope query_id)
    _ = copyField(37, &ev.event_id, query_id);

    const ts = std.mem.sliceTo(&decision.timestamp, 0);
    _ = copyField(32, &ev.valid_time, ts);
    _ = copyField(32, &ev.tx_time,   ts);

    const severity: []const u8 = switch (decision.access_level) {
        .anonymous, .authenticated => "info",
        .invalid                   => "warning",
    };
    _ = copyField(16, &ev.severity, severity);

    const reason = std.mem.sliceTo(&decision.reason, 0);
    const mod    = std.mem.sliceTo(&decision.module_name, 0);
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "{s} [module={s}]", .{ reason, mod }) catch reason;
    ev.message_len = copyField(256, &ev.message, msg);

    // Tags: policy-gate, phase-1, <module>, <access level>
    _ = copyField(32, &ev.tags[0], "policy-gate");
    _ = copyField(32, &ev.tags[1], "phase-1");
    _ = copyField(32, &ev.tags[2], mod);
    const level_tag: []const u8 = switch (decision.access_level) {
        .anonymous     => "anonymous",
        .authenticated => "authenticated",
        .invalid       => "invalid-key",
    };
    _ = copyField(32, &ev.tags[3], level_tag);
    ev.tag_count = 4;

    return ev;
}
