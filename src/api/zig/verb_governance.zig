// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// verb_governance.zig — HTTP Verb Governance, Stealth Mode & Timing Jitter
//
// Enforces which HTTP methods are permitted per route. Stealth mode returns
// 404 (not 403/405) for denied requests. Timing jitter on stealth denials
// closes the timing side-channel.
//
// Phase 1: hardcoded rules. Phase 2: YAML policy file loaded at startup.
//
// Replaces: verb_governance.v

const std = @import("std");
const t   = @import("types.zig");

/// A verb rule: URL prefix and its allowed methods.
const VerbRule = struct {
    pattern: []const u8,
    verbs:   []const []const u8,
    name:    []const u8,
};

/// Number of hardcoded rules.
const RULE_COUNT = 6;

/// Hardcoded verb rules for Aerie Phase 1.
const RULES: [RULE_COUNT]VerbRule = .{
    .{ .pattern = "/graphql",              .verbs = &.{ "POST", "OPTIONS" }, .name = "graphql-endpoint" },
    .{ .pattern = "/api/v1/health",        .verbs = &.{ "GET",  "OPTIONS" }, .name = "health-check"    },
    .{ .pattern = "/api/v1/telemetry",     .verbs = &.{ "GET",  "OPTIONS" }, .name = "rest-telemetry"  },
    .{ .pattern = "/api/v1/routes",        .verbs = &.{ "GET",  "OPTIONS" }, .name = "rest-routes"     },
    .{ .pattern = "/api/v1/audit/temporal",.verbs = &.{ "GET",  "OPTIONS" }, .name = "rest-temporal"   },
    .{ .pattern = "/api/v1/audit",         .verbs = &.{ "GET",  "OPTIONS" }, .name = "rest-audit"      },
};

/// Copy `src` into fixed buffer `dst`, null-terminating; returns length written.
fn copyField(comptime N: usize, dst: *[N]u8, src: []const u8) usize {
    const n = @min(src.len, N - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
    return n;
}

/// Check whether `method` is in `verbs`.
fn verbAllowed(method: []const u8, verbs: []const []const u8) bool {
    for (verbs) |v| {
        if (std.ascii.eqlIgnoreCase(method, v)) return true;
    }
    return false;
}

/// Strip query string from URL, returning just the path portion.
fn pathOnly(url: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, url, '?')) |qi| return url[0..qi];
    return url;
}

/// Find the most specific matching rule for a URL path using prefix matching.
///
/// Rules are checked from most-specific (longest pattern) to least-specific
/// to ensure /api/v1/audit/temporal wins over /api/v1/audit.
fn findRule(url: []const u8) ?VerbRule {
    const path = pathOnly(url);
    var best: ?VerbRule = null;
    var best_len: usize = 0;
    for (RULES) |rule| {
        if (std.mem.startsWith(u8, path, rule.pattern)) {
            if (rule.pattern.len > best_len) {
                best     = rule;
                best_len = rule.pattern.len;
            }
        }
    }
    return best;
}

/// Check an HTTP method + URL against the verb governance rules.
///
/// Stealth mode is always enabled: denied verbs receive 404-equivalent
/// responses, indistinguishable from genuine not-found.
pub fn check(method: []const u8, url: []const u8) t.VerbDecision {
    var dec: t.VerbDecision = std.mem.zeroes(t.VerbDecision);
    _ = copyField(16, &dec.verb, method);
    dec.verb_len = @min(method.len, 15);

    if (findRule(url)) |rule| {
        dec.matched  = true;
        _ = copyField(64, &dec.rule_name, rule.name);
        dec.rule_len = rule.name.len;

        if (verbAllowed(method, rule.verbs)) {
            dec.allowed = true;
            dec.stealth = false;
        } else {
            dec.allowed = false;
            dec.stealth = true;   // stealth mode always on
        }
        return dec;
    }

    // No rule matched — CORS preflight is always allowed
    if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) {
        dec.allowed  = true;
        dec.matched  = true;
        _ = copyField(64, &dec.rule_name, "cors-preflight");
        dec.rule_len = 14;
        dec.stealth  = false;
        return dec;
    }

    // Unknown route — deny
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

/// Apply stealth timing jitter: sleep 1–8ms before sending a stealth denial.
/// This closes the timing side-channel that would otherwise distinguish
/// fast stealth-denials (<0.1ms) from genuine responses (2–10ms).
pub fn stealthDelay() void {
    var seed: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&seed));
    const jitter_ms: u64 = 1 + (seed % 8);  // [1,8] ms
    std.Thread.sleep(jitter_ms * std.time.ns_per_ms);
}
