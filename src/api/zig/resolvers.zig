// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// resolvers.zig — protocol-neutral resolution via the aspect pipeline.
//
// Phase 2 of the weave: each resolution is a PRODUCER (probe/query ->
// payload JSON) plus an ASPECT LIST (data). The five-step pipeline
// (cache read -> produce -> envelope -> cache write -> audit) lives
// once in aspects.zig; these lists are the single source the route
// table references and /api/v1/meta renders.
//
// Replaces: resolvers.v

const std = @import("std");
const t = @import("types.zig");
const prf = @import("proof.zig");
const rc = @import("redis_client.zig");
const vc = @import("verisim_client.zig");
const ls = @import("librespeed_client.zig");
const hg = @import("hyperglass_client.zig");
const sp = @import("smokeping_client.zig");
const ctx = @import("ctx.zig");
const a = @import("aspects.zig");
const respond = @import("respond.zig");

pub const TemporalParams = t.TemporalParams;

// ---------------------------------------------------------------------------
// Aspect lists — the weave's data (referenced by router.zig; rendered
// by /api/v1/meta). One source of truth for behaviour and description.
// ---------------------------------------------------------------------------

pub const telemetry_aspects = [_]a.Aspect{ .{ .cache = .{ .ttl_s = 30 } }, .enveloped, .audited };
pub const routes_aspects = [_]a.Aspect{ .{ .cache = .{ .ttl_s = 60 } }, .enveloped, .audited };
pub const audit_aspects = [_]a.Aspect{ .enveloped, .audited }; // never cached — always fresh
pub const smokeping_aspects = [_]a.Aspect{ .{ .cache = .{ .ttl_s = 120 } }, .enveloped, .audited };
pub const temporal_aspects = [_]a.Aspect{ .enveloped, .dual_audited };

// ---------------------------------------------------------------------------
// Producers (probe/query -> payload JSON into payload_buf)
// ---------------------------------------------------------------------------

fn fetchTelemetry(c: *ctx.Ctx, arg: []const u8, payload_buf: []u8) []const u8 {
    _ = c;
    _ = arg;
    var sample: t.TelemetrySample = undefined;
    ls.getTelemetry(&sample);
    return ls.telemetryPayloadToJson(sample, payload_buf) catch
        errorJson("telemetry probe failed", payload_buf);
}

fn fetchRoutes(c: *ctx.Ctx, arg: []const u8, payload_buf: []u8) []const u8 {
    _ = c;
    var hops: [hg.MAX_HOPS]t.RouteHop = undefined;
    const hop_count = hg.getRouteForensics(arg, &hops);
    return hg.routeForensicsToJson(arg, hops[0..hop_count], payload_buf) catch
        errorJson("route forensics serialise failed", payload_buf);
}

fn fetchAudit(c: *ctx.Ctx, arg: []const u8, payload_buf: []u8) []const u8 {
    const limit = std.fmt.parseInt(u32, arg, 10) catch 50;
    var events_list: std.ArrayList([]const u8) = .{};
    c.redis.getAuditLog(limit, &events_list, c.arena);
    return eventsJson("events", events_list.items, payload_buf) catch
        errorJson("audit serialise failed", payload_buf);
}

fn fetchSmokeping(c: *ctx.Ctx, arg: []const u8, payload_buf: []u8) []const u8 {
    _ = c;
    var current: t.SmokePingSample = undefined;
    var chart: [sp.MAX_CHART_POINTS]t.SmokeChartPoint = undefined;
    const chart_count = sp.getSmokepingData(arg, &current, &chart);
    return sp.smokepingPayloadToJson(current, chart[0..chart_count], payload_buf) catch
        errorJson("smokeping serialise failed", payload_buf);
}

fn fetchTemporal(c: *ctx.Ctx, arg: []const u8, payload_buf: []u8) []const u8 {
    const mode = arg;
    const params = c.temporal orelse t.TemporalParams{};

    var events_list: std.ArrayList([]const u8) = .{};
    if (std.mem.eql(u8, mode, "as_of")) {
        // Fixes the original's dangling block-local slice: the default
        // time lives in this producer frame, valid for the whole call.
        var time_buf: [32]u8 = undefined;
        const as_of = if (params.time.len > 0) params.time else blk: {
            prf.formatRfc3339(&time_buf);
            break :blk std.mem.sliceTo(&time_buf, 0);
        };
        c.verisim.queryAsOf(as_of, params.limit, &events_list, c.arena);
    } else if (std.mem.eql(u8, mode, "between")) {
        if (params.start.len == 0 or params.end.len == 0) {
            return errorJson("between mode requires start and end parameters", payload_buf);
        }
        c.verisim.queryBetween(params.start, params.end, params.limit, &events_list, c.arena);
    } else if (std.mem.eql(u8, mode, "history")) {
        if (params.event_id.len == 0) {
            return errorJson("history mode requires event_id parameter", payload_buf);
        }
        c.verisim.queryHistory(params.event_id, &events_list, c.arena);
    } else {
        return errorJson("Unknown temporal mode (available: as_of, between, history)", payload_buf);
    }

    var fbs = std.io.fixedBufferStream(payload_buf);
    const w = fbs.writer();
    w.print("{{\"mode\":\"{s}\",\"events\":[", .{mode}) catch
        return errorJson("temporal serialise failed", payload_buf);
    for (events_list.items, 0..) |ev, i| {
        if (i > 0) w.writeByte(',') catch break;
        w.writeAll(ev) catch break;
    }
    w.writeAll("]}") catch return errorJson("temporal serialise failed", payload_buf);
    return fbs.getWritten();
}

/// Render an events list as {"<key>":[...]} into `payload_buf`.
fn eventsJson(key: []const u8, events: []const []const u8, payload_buf: []u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(payload_buf);
    const w = fbs.writer();
    try w.writeAll("{\"");
    try w.writeAll(key);
    try w.writeAll("\":[");
    for (events, 0..) |ev, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll(ev);
    }
    try w.writeAll("]}");
    return fbs.getWritten();
}

// ---------------------------------------------------------------------------
// Resolutions — producer + aspect list, one line each
// ---------------------------------------------------------------------------

pub fn resolveTelemetry(c: *ctx.Ctx) void {
    a.run(c, &telemetry_aspects, "", fetchTelemetry);
}

pub fn resolveRoutes(c: *ctx.Ctx, target: []const u8) void {
    a.run(c, &routes_aspects, target, fetchRoutes);
}

pub fn resolveAudit(c: *ctx.Ctx, limit: u32) void {
    var lb: [16]u8 = undefined;
    const lim = std.fmt.bufPrint(&lb, "{d}", .{limit}) catch "50";
    a.run(c, &audit_aspects, lim, fetchAudit);
}

pub fn resolveSmokeping(c: *ctx.Ctx, target: []const u8) void {
    a.run(c, &smokeping_aspects, target, fetchSmokeping);
}

pub fn resolveTemporal(c: *ctx.Ctx, mode: []const u8, params: TemporalParams) void {
    c.temporal = params;
    defer c.temporal = null;
    a.run(c, &temporal_aspects, mode, fetchTemporal);
}

// ---------------------------------------------------------------------------
// GraphQL resolver dispatcher — same resolutions, GraphQL error shape
// ---------------------------------------------------------------------------

/// Resolve a GraphQL query string. Errors are reported GraphQL-style
/// (HTTP 200 with an errors array); successful resolutions run the
/// same aspect pipelines as REST/gRPC.
pub fn resolveGraphqlQuery(c: *ctx.Ctx, query: []const u8) void {
    if (std.mem.indexOf(u8, query, "telemetrySnapshot") != null) {
        resolveTelemetry(c);
        return;
    }

    if (std.mem.indexOf(u8, query, "routeForensicsSnapshot") != null) {
        const target = gqlArgStr(query, "target", c.arena) orelse
            return gqlFail(c, "routeForensicsSnapshot requires a target argument");
        resolveRoutes(c, target);
        return;
    }

    // Check temporalAuditSnapshot BEFORE auditSnapshot (substring ordering)
    if (std.mem.indexOf(u8, query, "temporalAuditSnapshot") != null) {
        const mode = gqlArgStr(query, "mode", c.arena) orelse
            return gqlFail(c, "temporalAuditSnapshot requires mode argument (as_of, between, history)");
        const params = TemporalParams{
            .time = gqlArgStr(query, "time", c.arena) orelse "",
            .start = gqlArgStr(query, "start", c.arena) orelse "",
            .end = gqlArgStr(query, "end", c.arena) orelse "",
            .event_id = gqlArgStr(query, "eventId", c.arena) orelse "",
            .limit = if (gqlArgInt(query, "limit") > 0) @intCast(gqlArgInt(query, "limit")) else 50,
        };
        resolveTemporal(c, mode, params);
        return;
    }

    if (std.mem.indexOf(u8, query, "auditSnapshot") != null) {
        const limit_val = gqlArgInt(query, "limit");
        resolveAudit(c, if (limit_val > 0) @intCast(limit_val) else 50);
        return;
    }

    if (std.mem.indexOf(u8, query, "smokePingSnapshot") != null) {
        const target = gqlArgStr(query, "target", c.arena) orelse
            return gqlFail(c, "smokePingSnapshot requires a target argument");
        resolveSmokeping(c, target);
        return;
    }

    gqlFail(c, "Unknown query. Available: telemetrySnapshot, routeForensicsSnapshot(target), " ++
        "auditSnapshot(limit), temporalAuditSnapshot(mode,...), smokePingSnapshot(target)");
}

fn gqlFail(c: *ctx.Ctx, msg: []const u8) void {
    respond.respond(c, 200, gqlError(msg, c.out_buf));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Write a plain {"error":"..."} JSON string into `out_buf`.
pub fn errorJson(msg: []const u8, out_buf: []u8) []const u8 {
    return std.fmt.bufPrint(out_buf, "{{\"error\":\"{s}\"}}", .{msg})
        catch "{\"error\":\"error\"}";
}

/// Write a GraphQL {"errors":[{"message":"..."}]} into `out_buf`.
pub fn gqlError(msg: []const u8, out_buf: []u8) []const u8 {
    return std.fmt.bufPrint(out_buf,
        "{{\"errors\":[{{\"message\":\"{s}\"}}]}}",
        .{msg},
    ) catch "{\"errors\":[{\"message\":\"error\"}]}";
}

/// Extract a string GraphQL argument like `target: "1.2.3.4"` from a query.
/// Returns an arena-owned slice, or null if absent.
fn gqlArgStr(query: []const u8, arg: []const u8, arena: std.mem.Allocator) ?[]u8 {
    var nb: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "{s}:", .{arg}) catch return null;
    const pos = std.mem.indexOf(u8, query, needle) orelse return null;
    const after = query[pos + needle.len ..];
    const q1 = std.mem.indexOfScalar(u8, after, '"') orelse return null;
    const inner = after[q1 + 1 ..];
    const q2 = std.mem.indexOfScalar(u8, inner, '"') orelse return null;
    return arena.dupe(u8, inner[0..q2]) catch null;
}

/// Extract an integer GraphQL argument like `limit: 42` from a query.
fn gqlArgInt(query: []const u8, arg: []const u8) i64 {
    var nb: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "{s}:", .{arg}) catch return 0;
    const pos = std.mem.indexOf(u8, query, needle) orelse return 0;
    var rest = std.mem.trimLeft(u8, query[pos + needle.len ..], " \t");
    _ = &rest;
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 0) return 0;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch 0;
}

/// Build an AuditEvent from a PolicyDecision for logging.
pub fn auditFromPolicy(decision: t.PolicyDecision) t.AuditEvent {
    const mod = std.mem.sliceTo(&decision.module_name, 0);
    const reason = std.mem.sliceTo(&decision.reason, 0);
    const ts = std.mem.sliceTo(&decision.timestamp, 0);

    var ev: t.AuditEvent = std.mem.zeroes(t.AuditEvent);
    prf.generateUuidV4(&ev.event_id);

    const n_vt = @min(ts.len, 31);
    @memcpy(ev.valid_time[0..n_vt], ts[0..n_vt]);
    ev.valid_time[n_vt] = 0;
    const n_tx = @min(ts.len, 31);
    @memcpy(ev.tx_time[0..n_tx], ts[0..n_tx]);
    ev.tx_time[n_tx] = 0;

    const severity: []const u8 = if (decision.allowed) "info" else "warning";
    const n_sv = @min(severity.len, 15);
    @memcpy(ev.severity[0..n_sv], severity[0..n_sv]);
    ev.severity[n_sv] = 0;

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "{s} [module={s}]", .{ reason, mod }) catch reason;
    ev.message_len = @min(msg.len, 255);
    @memcpy(ev.message[0..ev.message_len], msg[0..ev.message_len]);
    ev.message[ev.message_len] = 0;

    const copyTag = struct {
        fn f(dst: *[32]u8, src: []const u8) void {
            const n = @min(src.len, 31);
            @memcpy(dst[0..n], src[0..n]);
            dst[n] = 0;
        }
    }.f;
    copyTag(&ev.tags[0], "policy-gate");
    copyTag(&ev.tags[1], "phase-2");
    copyTag(&ev.tags[2], mod);
    const level_tag: []const u8 = if (!decision.allowed)
        "denied"
    else switch (decision.access_level) {
        .anonymous => "anonymous",
        .authenticated => "authenticated",
        .invalid => "invalid-key",
    };
    copyTag(&ev.tags[3], level_tag);
    ev.tag_count = 4;

    return ev;
}

/// Log a PolicyDecision audit event to Redis.
pub fn logAudit(redis: *rc.RedisClient, policy: t.PolicyDecision) void {
    redis.logAudit(auditFromPolicy(policy));
}

/// Log a PolicyDecision audit event to Redis AND VerisimDB (the
/// temporal module's dual-audit aspect).
pub fn logDualAudit(c: *ctx.Ctx) void {
    vc.dualLogAudit(c.redis, c.verisim, auditFromPolicy(c.policy));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolvers: aspect lists say what the resolutions do" {
    // telemetry: cached 30s, enveloped, audited
    try std.testing.expect(a.hasAspect(&telemetry_aspects, .cache));
    try std.testing.expectEqual(@as(u32, 30), a.cacheTtlOf(&telemetry_aspects));
    // audit: never cached, always fresh
    try std.testing.expect(!a.hasAspect(&audit_aspects, .cache));
    try std.testing.expect(a.hasAspect(&audit_aspects, .audited));
    // temporal: dual-audited
    try std.testing.expect(a.hasAspect(&temporal_aspects, .dual_audited));
}

test "resolvers: error payloads pass through un-enveloped" {
    var out: [256]u8 = undefined;
    const body = errorJson("telemetry probe failed", &out);
    try std.testing.expect(std.mem.startsWith(u8, body, "{\"error\":"));
}
