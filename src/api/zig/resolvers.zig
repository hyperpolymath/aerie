// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// resolvers.zig — GraphQL and REST Resolver Implementations
//
// Shared resolution logic used by all three protocols (REST, GraphQL, gRPC).
// Each resolver:
//   1. Checks the Redis cache (TTL varies by data freshness)
//   2. Queries the backend probe
//   3. Wraps the result in a ProofEnvelope
//   4. Caches the result
//   5. Logs the audit event
//
// Replaces: resolvers.v

const std  = @import("std");
const t    = @import("types.zig");
const prf  = @import("proof.zig");
const pol  = @import("policy.zig");
const rc   = @import("redis_client.zig");
const vc   = @import("verisim_client.zig");
const ls   = @import("librespeed_client.zig");
const hg   = @import("hyperglass_client.zig");
const sp   = @import("smokeping_client.zig");

/// Resolve telemetry from LibreSpeed.
/// Checks the cache (30s TTL) before querying the probe.
/// Writes the final JSON into `out_buf`; returns a slice of it.
pub fn resolveTelemetry(
    redis:  *rc.RedisClient,
    policy: t.PolicyDecision,
    out_buf: []u8,
    arena:   std.mem.Allocator,
) []const u8 {
    _ = arena;

    // Cache check
    var cache_buf: [8192]u8 = undefined;
    const cached = redis.getCached("telemetry", &cache_buf);
    if (cached.len > 0) {
        const n = @min(cached.len, out_buf.len);
        @memcpy(out_buf[0..n], cached[0..n]);
        return out_buf[0..n];
    }

    // Probe LibreSpeed
    var sample: t.TelemetrySample = undefined;
    ls.getTelemetry(&sample);

    var payload_buf: [512]u8 = undefined;
    const payload_json = ls.telemetryPayloadToJson(sample, &payload_buf) catch
        return errorJson("telemetry probe failed", out_buf);

    // Wrap in proof
    var ctx_buf: [128]u8 = undefined;
    const ctx = prf.policyContextString("telemetry", &ctx_buf) catch "aerie-policy-v1";

    const result = prf.wrapBodyWithProof(payload_json, ctx, out_buf) catch
        return errorJson("proof wrap failed", out_buf);

    // Cache for 30 seconds
    redis.cacheResult("telemetry", result, 30);

    // Audit
    logAudit(redis, policy);

    return result;
}

/// Resolve BGP route forensics from Hyperglass for `target`.
/// Checks the cache (60s TTL).
pub fn resolveRouteForensics(
    target:  []const u8,
    redis:   *rc.RedisClient,
    policy:  t.PolicyDecision,
    out_buf: []u8,
    arena:   std.mem.Allocator,
) []const u8 {
    _ = arena;

    var key_buf: [128]u8 = undefined;
    const cache_key = std.fmt.bufPrint(&key_buf, "routes:{s}", .{target}) catch "routes";

    var cache_buf: [16384]u8 = undefined;
    const cached = redis.getCached(cache_key, &cache_buf);
    if (cached.len > 0) {
        const n = @min(cached.len, out_buf.len);
        @memcpy(out_buf[0..n], cached[0..n]);
        return out_buf[0..n];
    }

    var hops: [hg.MAX_HOPS]t.RouteHop = undefined;
    const hop_count = hg.getRouteForensics(target, &hops);

    var payload_buf: [8192]u8 = undefined;
    const payload_json = hg.routeForensicsToJson(target, hops[0..hop_count], &payload_buf)
        catch return errorJson("route forensics serialise failed", out_buf);

    var ctx_buf: [128]u8 = undefined;
    const ctx = prf.policyContextString("routes", &ctx_buf) catch "aerie-policy-v1";

    const result = prf.wrapBodyWithProof(payload_json, ctx, out_buf) catch
        return errorJson("proof wrap failed", out_buf);

    redis.cacheResult(cache_key, result, 60);
    logAudit(redis, policy);
    return result;
}

/// Resolve audit events from the Redis log.
/// Never cached — always fresh.
pub fn resolveAudit(
    limit:   u32,
    redis:   *rc.RedisClient,
    policy:  t.PolicyDecision,
    out_buf: []u8,
    arena:   std.mem.Allocator,
) []const u8 {
    var events_list: std.ArrayList([]const u8) = .{};
    redis.getAuditLog(limit, &events_list, arena);

    var events_buf: [32768]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&events_buf);
    const w = fbs.writer();
    w.writeAll("{\"events\":[") catch return errorJson("audit serialise failed", out_buf);
    for (events_list.items, 0..) |ev, i| {
        if (i > 0) w.writeByte(',') catch break;
        w.writeAll(ev) catch break;
    }
    w.writeAll("]}") catch return errorJson("audit serialise failed", out_buf);
    const data_json = fbs.getWritten();

    var ctx_buf: [128]u8 = undefined;
    const ctx = prf.policyContextString("audit", &ctx_buf) catch "aerie-policy-v1";

    const result = prf.wrapBodyWithProof(data_json, ctx, out_buf) catch
        return errorJson("proof wrap failed", out_buf);

    logAudit(redis, policy);
    return result;
}

/// Resolve SmokePing latency/jitter for `target`.
/// Checks the cache (120s TTL — data changes slowly).
pub fn resolveSmokeping(
    target:  []const u8,
    redis:   *rc.RedisClient,
    policy:  t.PolicyDecision,
    out_buf: []u8,
    arena:   std.mem.Allocator,
) []const u8 {
    _ = arena;

    var key_buf: [128]u8 = undefined;
    const cache_key = std.fmt.bufPrint(&key_buf, "smokeping:{s}", .{target}) catch "smokeping";

    var cache_buf: [32768]u8 = undefined;
    const cached = redis.getCached(cache_key, &cache_buf);
    if (cached.len > 0) {
        const n = @min(cached.len, out_buf.len);
        @memcpy(out_buf[0..n], cached[0..n]);
        return out_buf[0..n];
    }

    var current: t.SmokePingSample = undefined;
    var chart: [sp.MAX_CHART_POINTS]t.SmokeChartPoint = undefined;
    const chart_count = sp.getSmokepingData(target, &current, &chart);

    var payload_buf: [65536]u8 = undefined;
    const payload_json = sp.smokepingPayloadToJson(current, chart[0..chart_count], &payload_buf)
        catch return errorJson("smokeping serialise failed", out_buf);

    var ctx_buf: [128]u8 = undefined;
    const ctx = prf.policyContextString("smokeping", &ctx_buf) catch "aerie-policy-v1";

    const result = prf.wrapBodyWithProof(payload_json, ctx, out_buf) catch
        return errorJson("proof wrap failed", out_buf);

    redis.cacheResult(cache_key, result, 120);
    logAudit(redis, policy);
    return result;
}

/// TemporalParams bundles query parameters for temporal audit queries.
pub const TemporalParams = struct {
    time:     []const u8 = "",
    start:    []const u8 = "",
    end:      []const u8 = "",
    event_id: []const u8 = "",
    limit:    u32        = 50,
};

/// Resolve temporal audit from VerisimDB.
/// mode: "as_of", "between", or "history".
pub fn resolveTemporalAudit(
    mode:      []const u8,
    params:    TemporalParams,
    redis:     *rc.RedisClient,
    verisimdb: *const vc.VerisimDBClient,
    policy:    t.PolicyDecision,
    out_buf:   []u8,
    arena:     std.mem.Allocator,
) []const u8 {
    var events_list: std.ArrayList([]const u8) = .{};

    if (std.mem.eql(u8, mode, "as_of")) {
        const as_of = if (params.time.len > 0) params.time else blk: {
            var ts_buf: [32]u8 = undefined;
            prf.formatRfc3339(&ts_buf);
            // Return current time — but we need a stable slice; use out_buf scratch
            var scratch: [32]u8 = undefined;
            prf.formatRfc3339(&scratch);
            break :blk std.mem.sliceTo(&scratch, 0);
        };
        verisimdb.queryAsOf(as_of, params.limit, &events_list, arena);
    } else if (std.mem.eql(u8, mode, "between")) {
        if (params.start.len == 0 or params.end.len == 0) {
            return errorJson("between mode requires start and end parameters", out_buf);
        }
        verisimdb.queryBetween(params.start, params.end, params.limit, &events_list, arena);
    } else if (std.mem.eql(u8, mode, "history")) {
        if (params.event_id.len == 0) {
            return errorJson("history mode requires event_id parameter", out_buf);
        }
        verisimdb.queryHistory(params.event_id, &events_list, arena);
    } else {
        return errorJson("Unknown temporal mode (available: as_of, between, history)", out_buf);
    }

    var data_buf: [32768]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&data_buf);
    const w = fbs.writer();
    w.print("{{\"mode\":\"{s}\",\"events\":[", .{mode}) catch
        return errorJson("temporal serialise failed", out_buf);
    for (events_list.items, 0..) |ev, i| {
        if (i > 0) w.writeByte(',') catch break;
        w.writeAll(ev) catch break;
    }
    w.writeAll("]}") catch return errorJson("temporal serialise failed", out_buf);
    const data_json = fbs.getWritten();

    var ctx_buf: [128]u8 = undefined;
    const ctx = prf.policyContextString("temporal_audit", &ctx_buf) catch "aerie-policy-v1";

    const result = prf.wrapBodyWithProof(data_json, ctx, out_buf) catch
        return errorJson("proof wrap failed", out_buf);

    vc.dualLogAudit(redis, verisimdb, auditFromPolicy(policy));
    return result;
}

// ---------------------------------------------------------------------------
// GraphQL resolver dispatcher
// ---------------------------------------------------------------------------

/// Resolve a GraphQL query string, dispatching to the appropriate resolver.
/// Mirrors resolve_graphql_query() in resolvers.v.
pub fn resolveGraphqlQuery(
    query:     []const u8,
    redis:     *rc.RedisClient,
    verisimdb: *const vc.VerisimDBClient,
    policy:    t.PolicyDecision,
    out_buf:   []u8,
    arena:     std.mem.Allocator,
) []const u8 {
    if (std.mem.indexOf(u8, query, "telemetrySnapshot") != null) {
        return resolveTelemetry(redis, policy, out_buf, arena);
    }

    if (std.mem.indexOf(u8, query, "routeForensicsSnapshot") != null) {
        const target = gqlArgStr(query, "target", arena) orelse
            return gqlError("routeForensicsSnapshot requires a target argument", out_buf);
        defer arena.free(target);
        return resolveRouteForensics(target, redis, policy, out_buf, arena);
    }

    // Check temporalAuditSnapshot BEFORE auditSnapshot (substring match ordering)
    if (std.mem.indexOf(u8, query, "temporalAuditSnapshot") != null) {
        const mode = gqlArgStr(query, "mode", arena) orelse
            return gqlError("temporalAuditSnapshot requires mode argument (as_of, between, history)", out_buf);
        defer arena.free(mode);

        const time_val  = gqlArgStr(query, "time",    arena);
        const start_val = gqlArgStr(query, "start",   arena);
        const end_val   = gqlArgStr(query, "end",     arena);
        const eid_val   = gqlArgStr(query, "eventId", arena);
        defer { if (time_val)  |v| arena.free(v); }
        defer { if (start_val) |v| arena.free(v); }
        defer { if (end_val)   |v| arena.free(v); }
        defer { if (eid_val)   |v| arena.free(v); }

        const limit_val = gqlArgInt(query, "limit");
        const params = TemporalParams{
            .time     = if (time_val)  |v| v else "",
            .start    = if (start_val) |v| v else "",
            .end      = if (end_val)   |v| v else "",
            .event_id = if (eid_val)   |v| v else "",
            .limit    = if (limit_val > 0) @intCast(limit_val) else 50,
        };
        return resolveTemporalAudit(mode, params, redis, verisimdb, policy, out_buf, arena);
    }

    if (std.mem.indexOf(u8, query, "auditSnapshot") != null) {
        const limit_val = gqlArgInt(query, "limit");
        const limit: u32 = if (limit_val > 0) @intCast(limit_val) else 50;
        return resolveAudit(limit, redis, policy, out_buf, arena);
    }

    if (std.mem.indexOf(u8, query, "smokePingSnapshot") != null) {
        const target = gqlArgStr(query, "target", arena) orelse
            return gqlError("smokePingSnapshot requires a target argument", out_buf);
        defer arena.free(target);
        return resolveSmokeping(target, redis, policy, out_buf, arena);
    }

    return gqlError(
        "Unknown query. Available: telemetrySnapshot, routeForensicsSnapshot(target), " ++
        "auditSnapshot(limit), temporalAuditSnapshot(mode,...), smokePingSnapshot(target)",
        out_buf,
    );
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
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 0) return 0;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch 0;
}

/// Build an AuditEvent from a PolicyDecision for logging.
fn auditFromPolicy(decision: t.PolicyDecision) t.AuditEvent {
    const mod = std.mem.sliceTo(&decision.module_name, 0);
    const reason = std.mem.sliceTo(&decision.reason, 0);
    const ts = std.mem.sliceTo(&decision.timestamp, 0);

    var ev: t.AuditEvent = std.mem.zeroes(t.AuditEvent);

    // Generate a fresh UUID for this event
    prf.generateUuidV4(&ev.event_id);

    const n_vt = @min(ts.len, 31); @memcpy(ev.valid_time[0..n_vt], ts[0..n_vt]); ev.valid_time[n_vt] = 0;
    const n_tx = @min(ts.len, 31); @memcpy(ev.tx_time[0..n_tx],    ts[0..n_tx]); ev.tx_time[n_tx]    = 0;

    const severity: []const u8 = switch (decision.access_level) {
        .anonymous, .authenticated => "info",
        .invalid                   => "warning",
    };
    const n_sv = @min(severity.len, 15); @memcpy(ev.severity[0..n_sv], severity[0..n_sv]); ev.severity[n_sv] = 0;

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "{s} [module={s}]", .{ reason, mod }) catch reason;
    ev.message_len = @min(msg.len, 255);
    @memcpy(ev.message[0..ev.message_len], msg[0..ev.message_len]);
    ev.message[ev.message_len] = 0;

    const copyTag = struct {
        fn f(dst: *[32]u8, src: []const u8) void {
            const n = @min(src.len, 31); @memcpy(dst[0..n], src[0..n]); dst[n] = 0;
        }
    }.f;
    copyTag(&ev.tags[0], "policy-gate");
    copyTag(&ev.tags[1], "phase-1");
    copyTag(&ev.tags[2], mod);
    const level_tag: []const u8 = switch (decision.access_level) {
        .anonymous     => "anonymous",
        .authenticated => "authenticated",
        .invalid       => "invalid-key",
    };
    copyTag(&ev.tags[3], level_tag);
    ev.tag_count = 4;

    return ev;
}

/// Log a PolicyDecision audit event to Redis.
fn logAudit(redis: *rc.RedisClient, policy: t.PolicyDecision) void {
    redis.logAudit(auditFromPolicy(policy));
}
