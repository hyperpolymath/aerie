// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// respond.zig — the single response write path. Every reply — success,
// error, 404, protocol toggle — funnels through respond()/respondError();
// the ~15 copy-pasted resp.* blocks of the old handler collapse to one
// home. Transport-level hardening headers are owned by the FFI server
// (gnosis.zig writeGnosisResponse); this layer owns application shape.

const std = @import("std");
const ctx = @import("ctx.zig");
const errors = @import("errors.zig");

const AERIE_CT_JSON: [*:0]const u8 = "application/json";

/// Set the response (status + body). The body must outlive the call
/// (slice of ctx.out_buf, arena, or a literal).
pub fn respond(c: *ctx.Ctx, status: u16, body: []const u8) void {
    c.status = status;
    c.resp_body = body;
}

/// Respond with a JSON error envelope. The body is copied into the
/// gnosis-owned response scratch (the arena dies before the socket
/// write — see ctx.Ctx). The message is gateway-authored (no user
/// input), so no JSON escaping is applied; if that ever changes,
/// escape here — single home.
pub fn respondError(c: *ctx.Ctx, status: u16, message: []const u8) void {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{message}) catch "{\"error\":\"internal error\"}";
    const owned = c.copyToBody(body, "{\"error\":\"internal error\"}");
    respond(c, status, owned);
}

/// Respond from the error taxonomy (status + canonical message).
pub fn respondApiError(c: *ctx.Ctx, err: errors.ApiError) void {
    respondError(c, errors.statusOf(err), errors.messageOf(err));
}

/// Map the Ctx response slot onto the C ABI GnosisResponse. Called once,
/// at the end of dispatch, from the edge handler.
pub fn fillGnosisResponse(
    c: *ctx.Ctx,
    resp: anytype, // *GnosisResponse (typed via @cImport at the call site)
    writeFn: anytype, // uapi_gnosis_write_response equivalent
) void {
    const body: []const u8 = c.resp_body;
    writeFn(
        resp,
        c.status,
        AERIE_CT_JSON,
        if (body.len > 0) @as(?[*]const u8, @ptrCast(body.ptr)) else null,
        @intCast(body.len),
    );
}

test "respond: status and body land in the ctx slot" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var c = ctx.Ctx{
        .arena = arena_inst.allocator(),
        .method = "GET",
        .path = "/",
        .query = "",
        .body = "",
        .header_names = null,
        .header_values = null,
        .header_count = 0,
        .cfg = undefined,
        .redis = undefined,
        .verisim = undefined,
    };
    respond(&c, 429, "{\"error\":\"slow down\"}");
    try std.testing.expectEqual(@as(u16, 429), c.status);
    try std.testing.expectEqualStrings("{\"error\":\"slow down\"}", c.resp_body);

    respondApiError(&c, errors.ApiError.NotFound);
    try std.testing.expectEqual(@as(u16, 404), c.status);
}
