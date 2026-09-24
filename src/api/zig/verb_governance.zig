// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// verb_governance.zig — HTTP verb governance, stealth mode & timing
// jitter. The verb ASPECT; the route DATA lives in router.zig — this
// module no longer keeps a second copy of the table (the three-tables-
// in-sync hazard is gone). Stealth mode returns 404 (not 403/405) for
// denied requests; timing jitter on stealth denials closes the timing
// side-channel.
//
// Replaces: verb_governance.v, and the Phase-1 hardcoded RULES.

const std = @import("std");
const t = @import("types.zig");
const router = @import("router.zig");

/// Check `method` against the route table (longest-prefix, boundary-
/// guarded). OPTIONS on an unmatched path is CORS preflight: allowed.
pub fn check(method: []const u8, url: []const u8) t.VerbDecision {
    var dec: t.VerbDecision = std.mem.zeroes(t.VerbDecision);
    _ = copyField(16, &dec.verb, method);
    dec.verb_len = @min(method.len, 15);

    const path = pathOnly(url);
    if (router.find(path)) |route| {
        dec.matched = true;
        _ = copyField(64, &dec.rule_name, route.module);
        dec.rule_len = route.module.len;
        dec.allowed = router.verbAllowed(route, method);
        dec.stealth = !dec.allowed; // stealth mode always on
        return dec;
    }

    // No rule matched — CORS preflight is always allowed.
    if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) {
        dec.allowed = true;
        dec.matched = true;
        _ = copyField(64, &dec.rule_name, "cors-preflight");
        dec.rule_len = 14;
        dec.stealth = false;
        return dec;
    }

    // Unknown route — deny.
    dec.allowed = false;
    dec.matched = false;
    dec.stealth = true;
    return dec;
}

/// HTTP status code for a denial decision.
/// Stealth mode returns 404; normal mode returns 405.
pub fn denialStatusCode(dec: t.VerbDecision) u16 {
    return if (dec.stealth) 404 else 405;
}

/// Apply stealth timing jitter: sleep 1–8ms before sending a stealth
/// denial. Closes the timing side-channel that would otherwise
/// distinguish fast stealth-denials (<0.1ms) from genuine responses
/// (2–10ms).
pub fn stealthDelay() void {
    var seed: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&seed));
    const jitter_ms: u64 = 1 + (seed % 8); // [1,8] ms
    std.Thread.sleep(jitter_ms * std.time.ns_per_ms);
}

/// Strip query string from URL, returning just the path portion.
fn pathOnly(url: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, url, '?')) |qi| return url[0..qi];
    return url;
}

/// Copy `src` into fixed buffer `dst`, null-terminating; returns length.
fn copyField(comptime N: usize, dst: *[N]u8, src: []const u8) usize {
    const n = @min(src.len, N - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
    return n;
}

// ---------------------------------------------------------------------------
// Tests — the table is in router.zig; these prove the aspect reads it.
// ---------------------------------------------------------------------------

test "verb governance: table-driven allow/deny with stealth" {
    const ok = check("GET", "/api/v1/smokeping?target=x");
    try std.testing.expect(ok.allowed and ok.matched and !ok.stealth);
    try std.testing.expectEqualStrings("smokeping", std.mem.sliceTo(&ok.rule_name, 0));

    const denied = check("POST", "/api/v1/telemetry");
    try std.testing.expect(!denied.allowed and denied.matched and denied.stealth);
    try std.testing.expectEqual(@as(u16, 404), denialStatusCode(denied));

    const unmatched = check("GET", "/nope");
    try std.testing.expect(!unmatched.allowed and !unmatched.matched and unmatched.stealth);

    const preflight = check("OPTIONS", "/nope");
    try std.testing.expect(preflight.allowed and preflight.matched);
}

test "verb governance: graphql accepts GET and POST" {
    try std.testing.expect(check("GET", "/graphql").allowed);
    try std.testing.expect(check("POST", "/graphql").allowed);
    try std.testing.expect(!check("DELETE", "/graphql").allowed);
}
