// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// policy.zig — the policy gate (Phase 2: keystore + deny-by-default).
//
// Two modes:
//   * open  — Phase-1 semantics (permissive; format-check keys; for
//             local development). Set AERIE_AUTH_MODE=open.
//   * deny  — DEFAULT. The keystore decides: missing/unknown/malformed
//             key or missing module entitlement => denied. Public
//             routes (health, meta) are exempted by the router, not
//             here — every decision is still recorded.
//
// Replaces: policy.v

const std = @import("std");
const t = @import("types.zig");
const prf = @import("proof.zig");
const ks = @import("keystore.zig");
const config = @import("config.zig");

const empty_store = ks.KeyStore.init();

/// Redact an API key to "first8chars...". Result placed in `out`.
fn redactKey(key: []const u8, out: *[64]u8) usize {
    const prefix_len = @min(key.len, 8);
    @memcpy(out[0..prefix_len], key[0..prefix_len]);
    @memcpy(out[prefix_len..][0..3], "...");
    out[prefix_len + 3] = 0;
    return prefix_len + 3;
}

/// Copy `src` into the fixed-length field `dst`, null-terminating.
fn copyField(comptime N: usize, dst: *[N]u8, src: []const u8) usize {
    const n = @min(src.len, N - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
    return n;
}

/// Evaluate the policy gate for an incoming request.
///
/// Deny mode (default): the keystore authorizes key x module; denials
/// carry the reason. Open mode: permissive Phase-1 semantics for local
/// development. Every decision (allowed or not) is audit-logged by the
/// dispatch pipeline.
pub fn evaluatePolicy(
    store: ?*const ks.KeyStore,
    mode: config.AuthMode,
    api_key: []const u8,
    module_name: []const u8,
) t.PolicyDecision {
    var dec: t.PolicyDecision = std.mem.zeroes(t.PolicyDecision);
    dec.module_len = copyField(64, &dec.module_name, module_name);

    var ts_buf: [32]u8 = undefined;
    prf.formatRfc3339(&ts_buf);
    dec.timestamp_len = copyField(32, &dec.timestamp, std.mem.sliceTo(&ts_buf, 0));

    if (api_key.len > 0) {
        dec.api_key_len = redactKey(api_key, &dec.api_key);
    }

    if (mode == .open) {
        dec.allowed = true;
        if (api_key.len == 0) {
            dec.access_level = .anonymous;
            dec.reason_len = copyField(128, &dec.reason, "open mode: anonymous access allowed");
        } else if (ks.isValidKeyFormat(api_key)) {
            dec.access_level = .authenticated;
            dec.reason_len = copyField(128, &dec.reason, "open mode: key format valid (not verified)");
        } else {
            dec.access_level = .invalid;
            dec.reason_len = copyField(128, &dec.reason, "open mode: malformed key (allowed)");
        }
        return dec;
    }

    // Deny mode: the keystore decides.
    const store_ptr = store orelse &empty_store;
    const authz = store_ptr.authorize(api_key, module_name);
    switch (authz) {
        .granted => |g| {
            dec.allowed = true;
            dec.access_level = .authenticated;
            var rb: [128]u8 = undefined;
            const r = std.fmt.bufPrint(&rb, "key '{s}' authorized for module '{s}'", .{ g.name, module_name }) catch "key authorized";
            dec.reason_len = copyField(128, &dec.reason, r);
        },
        .denied => |d| {
            dec.allowed = false;
            dec.access_level = switch (d) {
                .missing_key => .anonymous,
                .malformed_key, .unknown_key => .invalid,
                .no_entitlement => .authenticated,
            };
            dec.reason_len = copyField(128, &dec.reason, authz.reason());
        },
    }
    return dec;
}

/// Convert a PolicyDecision into an AuditEvent for the Redis audit log.
/// `query_id` is used as the event_id (mirrors decision_to_audit_event
/// in policy.v).
pub fn decisionToAuditEvent(decision: t.PolicyDecision, query_id: []const u8) t.AuditEvent {
    var ev: t.AuditEvent = std.mem.zeroes(t.AuditEvent);
    _ = copyField(37, &ev.event_id, query_id);

    const ts = std.mem.sliceTo(&decision.timestamp, 0);
    _ = copyField(32, &ev.valid_time, ts);
    _ = copyField(32, &ev.tx_time, ts);

    const severity: []const u8 = if (decision.allowed)
        (if (decision.access_level == .authenticated) "info" else "info")
    else
        "warning";
    _ = copyField(16, &ev.severity, severity);

    const reason = std.mem.sliceTo(&decision.reason, 0);
    const mod = std.mem.sliceTo(&decision.module_name, 0);
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "{s} [module={s}]", .{ reason, mod }) catch reason;
    ev.message_len = copyField(256, &ev.message, msg);

    _ = copyField(32, &ev.tags[0], "policy-gate");
    _ = copyField(32, &ev.tags[1], "phase-2");
    _ = copyField(32, &ev.tags[2], mod);
    const level_tag: []const u8 = if (!decision.allowed)
        "denied"
    else switch (decision.access_level) {
        .anonymous => "anonymous",
        .authenticated => "authenticated",
        .invalid => "invalid-key",
    };
    _ = copyField(32, &ev.tags[3], level_tag);
    ev.tag_count = 4;

    return ev;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "policy: deny mode is the default posture and keystore decides" {
    var store = ks.KeyStore.init();
    try store.add("test-key-aaaaaaaaaaaaaaaa:ops:telemetry,routes");

    // entitled
    const g = evaluatePolicy(&store, .deny, "test-key-aaaaaaaaaaaaaaaa", "telemetry");
    try std.testing.expect(g.allowed);
    try std.testing.expect(g.access_level == .authenticated);

    // no entitlement -> denied, authenticated (maps to 403)
    const d1 = evaluatePolicy(&store, .deny, "test-key-aaaaaaaaaaaaaaaa", "audit");
    try std.testing.expect(!d1.allowed);
    try std.testing.expect(d1.access_level == .authenticated);

    // missing key -> denied, anonymous (401)
    const d2 = evaluatePolicy(&store, .deny, "", "telemetry");
    try std.testing.expect(!d2.allowed and d2.access_level == .anonymous);

    // unknown key -> denied, invalid (401)
    const d3 = evaluatePolicy(&store, .deny, "unknown-key-bbbbbbbbbbbbbb", "telemetry");
    try std.testing.expect(!d3.allowed and d3.access_level == .invalid);

    // null keystore in deny mode denies everything
    const d4 = evaluatePolicy(null, .deny, "test-key-aaaaaaaaaaaaaaaa", "telemetry");
    try std.testing.expect(!d4.allowed);
}

test "policy: open mode stays permissive for local development" {
    const a = evaluatePolicy(null, .open, "", "telemetry");
    try std.testing.expect(a.allowed and a.access_level == .anonymous);
    const b = evaluatePolicy(null, .open, "whatever", "telemetry");
    try std.testing.expect(b.allowed and b.access_level == .invalid);
}

test "policy: denial decisions audit as warnings with a denied tag" {
    const d = evaluatePolicy(null, .deny, "", "telemetry");
    const ev = decisionToAuditEvent(d, "00000000-0000-4000-8000-000000000000");
    const sev = std.mem.sliceTo(&ev.severity, 0);
    try std.testing.expectEqualStrings("warning", sev);
    const tag4 = std.mem.sliceTo(&ev.tags[3], 0);
    try std.testing.expectEqualStrings("denied", tag4);
}
