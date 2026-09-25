// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// ctx.zig — the request context: the single object every cross-cutting
// aspect reads and writes. Replacing the module-level globals
// (g_aerie_cfg / g_aerie_redis / g_aerie_resp_buf) with a per-request
// Ctx removes the shared-buffer serialisation hazard and makes every
// seam injectable for tests.
//
// Built from a GnosisRequestV2 (query + headers now real — the fix for
// the v1 information loss that starved the policy gate of X-Api-Key
// and the resolvers of query parameters).

const std = @import("std");
const t = @import("types.zig");
const config = @import("config.zig");
const router = @import("router.zig");
const rc = @import("redis_client.zig");
const vc = @import("verisim_client.zig");
const ks = @import("keystore.zig");

pub const Ctx = struct {
    // --- request (slices alias gnosis-owned storage; valid for the call)
    arena: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    query: []const u8,
    body: []const u8,
    header_names: ?[]const [*c]const u8,
    header_values: ?[]const [*c]const u8,
    header_count: usize,

    // --- services (stable pointers set before the server starts)
    cfg: *const config.Config,
    redis: *rc.RedisClient,
    verisim: *vc.VerisimDBClient,
    /// gnosis pool state, sampled per request (reflective health).
    pool_state: u8 = 0,

    // --- aspects (filled during dispatch)
    policy: t.PolicyDecision = std.mem.zeroes(t.PolicyDecision),
    route: ?*const router.Route = null,
    keystore: ?*const ks.KeyStore = null,
    /// Temporal-audit parameters extracted by the protocol adapter
    /// (REST query / gRPC body / GraphQL args) and consumed by the
    /// temporal producer.
    temporal: ?t.TemporalParams = null,

    // --- response slot (the ONLY place a response is assembled).
    // out_buf is the gnosis-owned per-connection scratch: it outlives the
    // handler call, so response bodies MUST live here (or be literals) —
    // never in the request arena, which is freed when the handler returns.
    out_buf: []u8 = &.{},
    body_cursor: usize = 0,
    status: u16 = 200,
    resp_body: []const u8 = "",

    /// Case-insensitive header lookup. Returns a slice of the request's
    /// storage; empty string when absent.
    pub fn header(self: *const Ctx, name: []const u8) []const u8 {
        const names = self.header_names orelse return "";
        const values = self.header_values orelse return "";
        var i: usize = 0;
        while (i < self.header_count and i < names.len) : (i += 1) {
            const n = names[i];
            if (n == null) continue;
            if (std.ascii.eqlIgnoreCase(std.mem.span(n), name)) {
                const v = values[i];
                if (v == null) return "";
                return std.mem.span(v);
            }
        }
        return "";
    }

    /// Query parameter from the raw query string. Returns "" when absent
    /// (matching the gateway's historical adapter shape). No URL
    /// decoding — parameters in this API are simple tokens.
    pub fn queryParam(self: *const Ctx, name: []const u8) []const u8 {
        var pairs = std.mem.splitScalar(u8, self.query, '&');
        while (pairs.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
        return "";
    }

    /// Reserve `len` bytes of response scratch and return the slice, or
    /// null when exhausted. The single sanctioned way to place a response
    /// body whose source lifetime ends with the handler.
    pub fn takeBodySpace(self: *Ctx, len: usize) ?[]u8 {
        if (self.body_cursor + len > self.out_buf.len) return null;
        const dst = self.out_buf[self.body_cursor..][0..len];
        self.body_cursor += len;
        return dst;
    }

    /// Copy `bytes` into response scratch (for stack/arena-lifetime
    /// bodies). Falls back to `fallback` (a literal) when exhausted.
    pub fn copyToBody(self: *Ctx, bytes: []const u8, fallback: []const u8) []const u8 {
        const dst = self.takeBodySpace(bytes.len) orelse return fallback;
        @memcpy(dst, bytes);
        return dst;
    }

    /// Protocol-neutral parameter: REST query string, then JSON body
    /// field, then camelCase JSON field (event_id -> eventId). Returns
    /// "" when absent. This is what lets REST, gRPC-JSON and GraphQL
    /// adapters share one resolver signature.
    pub fn param(self: *const Ctx, name: []const u8) []const u8 {
        const q = self.queryParam(name);
        if (q.len > 0) return q;
        const j = self.jsonStrField(name);
        if (j.len > 0) return j;
        if (std.mem.indexOfScalar(u8, name, '_')) |_| {
            var cb: [32]u8 = undefined;
            var n: usize = 0;
            var upper = false;
            for (name) |ch| {
                if (ch == '_') {
                    upper = true;
                    continue;
                }
                if (n >= cb.len) break;
                cb[n] = if (upper) std.ascii.toUpper(ch) else ch;
                upper = false;
                n += 1;
            }
            return self.jsonStrField(cb[0..n]);
        }
        return "";
    }

    /// Extract a JSON string field from the request body without
    /// allocating (slice into the body). "" when absent.
    pub fn jsonStrField(self: *const Ctx, key: []const u8) []const u8 {
        return jsonStrFieldIn(self.body, key);
    }

    /// Extract a JSON integer field from the request body.
    pub fn jsonIntField(self: *const Ctx, key: []const u8) ?u32 {
        var nb: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&nb, "\"{s}\"", .{key}) catch return null;
        const kpos = std.mem.indexOf(u8, self.body, needle) orelse return null;
        const after = self.body[kpos + needle.len ..];
        const colon = std.mem.indexOfScalar(u8, after, ':') orelse return null;
        const rest = std.mem.trimLeft(u8, after[colon + 1 ..], " \t");
        var end: usize = 0;
        while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
        if (end == 0) return null;
        return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
    }
};

/// Zero-allocation JSON string-field extraction (slice into `data`).
pub fn jsonStrFieldIn(data: []const u8, key: []const u8) []const u8 {
    var nb: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "\"{s}\"", .{key}) catch return "";
    const kpos = std.mem.indexOf(u8, data, needle) orelse return "";
    const after = data[kpos + needle.len ..];
    const colon = std.mem.indexOfScalar(u8, after, ':') orelse return "";
    var rest = std.mem.trimLeft(u8, after[colon + 1 ..], " \t\n\r");
    if (rest.len == 0 or rest[0] != '"') return "";
    rest = rest[1..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
    return rest[0..q2];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ctx: header lookup is case-insensitive and absent-safe" {
    const names = [_][*c]const u8{ "X-Api-Key", "Content-Type" };
    const values = [_][*c]const u8{ "abcd-1234-efgh-5678", "application/json" };
    const c = Ctx{
        .arena = undefined,
        .method = "GET",
        .path = "/api/v1/routes",
        .query = "",
        .body = "",
        .header_names = &names,
        .header_values = &values,
        .header_count = 2,
        .cfg = undefined,
        .redis = undefined,
        .verisim = undefined,
    };
    try std.testing.expectEqualStrings("abcd-1234-efgh-5678", c.header("x-api-key"));
    try std.testing.expectEqualStrings("abcd-1234-efgh-5678", c.header("X-API-KEY"));
    try std.testing.expectEqualStrings("", c.header("x-nope"));
}

test "ctx: query params parse from the raw query" {
    const c = Ctx{
        .arena = undefined,
        .method = "GET",
        .path = "/api/v1/routes",
        .query = "target=198.51.100.9&limit=10",
        .body = "",
        .header_names = null,
        .header_values = null,
        .header_count = 0,
        .cfg = undefined,
        .redis = undefined,
        .verisim = undefined,
    };
    try std.testing.expectEqualStrings("198.51.100.9", c.queryParam("target"));
    try std.testing.expectEqualStrings("10", c.queryParam("limit"));
    try std.testing.expectEqualStrings("", c.queryParam("mode"));
}

test "ctx: param() falls back across protocols" {
    const c = Ctx{
        .arena = undefined,
        .method = "POST",
        .path = "/grpc/GetTemporalAuditSnapshot",
        .query = "",
        .body = "{\"mode\": \"as_of\", \"eventId\": \"abc-123\"}",
        .header_names = null,
        .header_values = null,
        .header_count = 0,
        .cfg = undefined,
        .redis = undefined,
        .verisim = undefined,
    };
    try std.testing.expectEqualStrings("as_of", c.param("mode"));
    try std.testing.expectEqualStrings("abc-123", c.param("event_id")); // camelCase fallback
    try std.testing.expectEqualStrings("", c.param("start"));

    const r = Ctx{
        .arena = undefined,
        .method = "GET",
        .path = "/api/v1/routes",
        .query = "target=198.51.100.9",
        .body = "",
        .header_names = null,
        .header_values = null,
        .header_count = 0,
        .cfg = undefined,
        .redis = undefined,
        .verisim = undefined,
    };
    try std.testing.expectEqualStrings("198.51.100.9", r.param("target"));
}

test "ctx: json field extraction from body" {
    const c = Ctx{
        .arena = undefined,
        .method = "POST",
        .path = "/grpc/GetAuditSnapshot",
        .query = "",
        .body = "{\"query\": \"{ telemetry }\", \"limit\": 25}",
        .header_names = null,
        .header_values = null,
        .header_count = 0,
        .cfg = undefined,
        .redis = undefined,
        .verisim = undefined,
    };
    try std.testing.expectEqualStrings("{ telemetry }", c.jsonStrField("query"));
    try std.testing.expectEqual(@as(u32, 25), c.jsonIntField("limit").?);
}
