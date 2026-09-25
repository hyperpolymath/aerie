// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// aspects.zig — the weave. Cross-cutting concerns are ASPECTS: data on
// the resolution, not code copied into every resolver. The pipeline
// below is the single implementation of what resolvers.zig used to
// hand-copy five times:
//
//     cache read -> produce payload -> proof envelope -> cache write
//     -> audit
//
// METAICONIC: the aspect list is data (rendered by /api/v1/meta from
// the same constants the pipeline interprets); adding cache/audit to a
// resolution is a table edit, not a code edit.
//
// Honesty notes: cached results are audited too (a served response is
// an auditable event — the old code skipped audit on cache hits);
// producer errors pass through un-enveloped and un-cached, exactly as
// the per-resolver code did.

const std = @import("std");
const ctx = @import("ctx.zig");
const res = @import("resolvers.zig");
const prf = @import("proof.zig");
const rc = @import("redis_client.zig");
const vc = @import("verisim_client.zig");
const respond = @import("respond.zig");

/// One cross-cutting concern, as data.
pub const Aspect = union(enum) {
    /// Read-through cache, key = module[:extra], TTL in seconds.
    cache: struct { ttl_s: u32 },
    /// Wrap the payload in the proof envelope (skip on error payloads).
    enveloped,
    /// Audit the resolution to Redis (runs on cache hits too).
    audited,
    /// Audit to Redis AND VerisimDB (temporal module).
    dual_audited,
};

/// A payload producer: probe/query and render the payload JSON into
/// `payload_buf` (stack storage provided by the pipeline), returning a
/// slice of it. `arg` is the resolution's primary parameter (target,
/// mode, limit-as-string) — adapters extract it from their protocol.
pub const Producer = *const fn (c: *ctx.Ctx, arg: []const u8, payload_buf: []u8) []const u8;

/// Does the list carry this aspect? (Public: resolvers' tests and
/// meta rendering ask the same question the pipeline asks.)
pub fn hasAspect(aspects_: []const Aspect, comptime tag: std.meta.Tag(Aspect)) bool {
    for (aspects_) |a| {
        if (a == tag) return true;
    }
    return false;
}

/// The cache TTL the list declares (0 when uncached).
pub fn cacheTtlOf(aspects_: []const Aspect) u32 {
    for (aspects_) |a| switch (a) {
        .cache => |spec| return spec.ttl_s,
        else => {},
    };
    return 0;
}

/// The pipeline. Runs the aspects around `producer` and places the
/// final body in the response slot.
pub fn run(c: *ctx.Ctx, aspects_: []const Aspect, extra: []const u8, producer: Producer) void {
    const mod = if (c.route) |r| r.module else "unknown";

    // 1. Cache read — a hit is served verbatim (it stores the enveloped
    //    body) and still audited.
    const caching = hasAspect(aspects_, .cache);
    var key_buf: [160]u8 = undefined;
    var cache_key: []const u8 = "";
    if (caching) {
        cache_key = if (extra.len > 0)
            std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ mod, extra }) catch mod
        else
            mod;
        const cached = c.redis.getCached(cache_key, c.out_buf);
        if (cached.len > 0) {
            if (hasAspect(aspects_, .audited)) res.logAudit(c.redis, c.policy);
            if (hasAspect(aspects_, .dual_audited)) res.logDualAudit(c);
            respond.respond(c, 200, cached);
            return;
        }
    }

    // 2. Produce the payload.
    var payload_buf: [65536]u8 = undefined;
    const payload = producer(c, extra, &payload_buf);
    const is_error = std.mem.startsWith(u8, payload, "{\"error\":");

    // 3. Envelope (errors pass through raw, matching the historical
    //    per-resolver behaviour).
    var result: []const u8 = undefined;
    if (hasAspect(aspects_, .enveloped) and !is_error) {
        var ctx_buf: [128]u8 = undefined;
        const pctx = prf.policyContextString(mod, &ctx_buf) catch "aerie-policy-v1";
        result = prf.wrapBodyWithProof(payload, pctx, c.out_buf) catch {
            respond.respondError(c, 500, "proof wrap failed");
            return;
        };
    } else {
        // payload lives in this frame's stack: copy into response scratch
        result = c.copyToBody(payload, "{\"error\":\"internal error\"}");
    }

    // 4. Cache write (never cache error payloads).
    if (caching and !is_error) {
        c.redis.cacheResult(cache_key, result, cacheTtlOf(aspects_));
    }

    // 5. Audit.
    if (hasAspect(aspects_, .audited)) res.logAudit(c.redis, c.policy);
    if (hasAspect(aspects_, .dual_audited)) res.logDualAudit(c);

    respond.respond(c, 200, result);
}

/// Render one aspect for /api/v1/meta (reflective description).
pub fn describe(a: Aspect, buf: []u8) []const u8 {
    return switch (a) {
        .cache => |spec| std.fmt.bufPrint(buf, "cache:{d}s", .{spec.ttl_s}) catch "cache",
        .enveloped => "enveloped",
        .audited => "audited",
        .dual_audited => "dual_audited",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "aspects: presence detection and ttl" {
    const aspects_ = [_]Aspect{ .{ .cache = .{ .ttl_s = 30 } }, .enveloped, .audited };
    try std.testing.expect(hasAspect(&aspects_, .cache));
    try std.testing.expect(hasAspect(&aspects_, .enveloped));
    try std.testing.expect(!hasAspect(&aspects_, .dual_audited));
    try std.testing.expectEqual(@as(u32, 30), cacheTtlOf(&aspects_));

    const none = [_]Aspect{.enveloped};
    try std.testing.expectEqual(@as(u32, 0), cacheTtlOf(&none));
}

test "aspects: describe renders for meta" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("cache:30s", describe(.{ .cache = .{ .ttl_s = 30 } }, &buf));
    try std.testing.expectEqualStrings("enveloped", describe(.enveloped, &buf));
}

fn testProducer(c: *ctx.Ctx, arg: []const u8, payload_buf: []u8) []const u8 {
    _ = c;
    _ = arg;
    return std.fmt.bufPrint(payload_buf, "{{\"ok\":true,\"from\":\"producer\"}}", .{}) catch "{}";
}

test "aspects: pipeline envelopes and copies to response scratch" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var redis = rc.RedisClient.init(std.testing.allocator);
    defer redis.deinit();

    var out: [1024]u8 = undefined;
    var c = ctx.Ctx{
        .arena = arena_inst.allocator(),
        .method = "GET",
        .path = "/api/v1/telemetry",
        .query = "",
        .body = "",
        .header_names = null,
        .header_values = null,
        .header_count = 0,
        .cfg = undefined,
        .redis = &redis,
        .verisim = undefined,
        .out_buf = &out,
    };

    const aspects_ = [_]Aspect{ .enveloped };
    run(&c, &aspects_, "", testProducer);

    try std.testing.expectEqual(@as(u16, 200), c.status);
    // enveloped: proof envelope present around the payload
    try std.testing.expect(std.mem.indexOf(u8, c.resp_body, "\"proof\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.resp_body, "\"from\":\"producer\"") != null);
}
