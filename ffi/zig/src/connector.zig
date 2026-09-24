// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// connector.zig — service connector pool: a minimal, correct HTTP/1.1
// client behind the uapi_connector_* C ABI (declared in src/abi/Gnosis.idr,
// header ffi/zig/include/zig_api.h).
//
// Superset-compatible with developer-ecosystem/zig-api semantics:
//   * transport success => UAPI_OK and the response body copied into the
//     caller's buffer, truncated to out_len-1, null-terminated;
//   * non-2xx statuses are NOT errors (the body is the payload — clients
//     parse it);
//   * only transport failures (connect/send/recv/timeout) return errors.
//
// Scope (prototype phase): http:// base URLs only (the compose topology is
// all-internal http; TLS terminates at the reverse proxy), Connection:
// close per call, Content-Length responses only. Connect itself blocks on
// DNS/TCP (documented; the resilience aspect in the gateway adds the
// timeouts that matter).

const std = @import("std");
const core = @import("core.zig");

const MAX_CONNECTORS: usize = 64;
const MAX_URL_LEN: usize = 256;
const IO_TIMEOUT_S: u32 = 5;
const MAX_RESPONSE_BYTES: usize = 4 << 20; // 4 MiB read cap

const Connector = struct {
    active: bool = false,
    service_id: u8 = 0,
    host: [MAX_URL_LEN]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 80,
    state: core.ConnectorState = .disconnected,
    requests_ok: u64 = 0,
    requests_err: u64 = 0,
};

var pool: [MAX_CONNECTORS]Connector = [1]Connector{.{}} ** MAX_CONNECTORS;
var pool_mutex: std.Thread.Mutex = .{};

/// Parse "http://host[:port][/...]" into host + port. Returns null on
/// malformed input or a non-http scheme.
fn parseBaseUrl(url: []const u8) ?struct { host: []const u8, port: u16 } {
    if (!std.mem.startsWith(u8, url, "http://") or url.len <= "http://".len) return null;
    const after = url["http://".len..];
    const authority = if (std.mem.indexOfScalar(u8, after, '/')) |i| after[0..i] else after;
    // Reject userinfo (not used in the compose topology) — fail closed.
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return null;
    if (std.mem.indexOfScalar(u8, authority, ':')) |ci| {
        const host = authority[0..ci];
        const port = std.fmt.parseInt(u16, authority[ci + 1 ..], 10) catch return null;
        if (host.len == 0) return null;
        return .{ .host = host, .port = port };
    }
    if (authority.len == 0) return null;
    return .{ .host = authority, .port = 80 };
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

pub export fn uapi_connector_create(service_id: u8, base_url: ?[*:0]const u8) callconv(.c) u8 {
    const url = std.mem.span(base_url orelse return 255);
    const parsed = parseBaseUrl(url) orelse {
        core.setError("connector: bad base_url (http://host[:port] only)", .{});
        return 255;
    };
    if (parsed.host.len >= MAX_URL_LEN) return 255;

    pool_mutex.lock();
    defer pool_mutex.unlock();
    for (&pool, 0..) |*slot, i| {
        if (!slot.active) {
            slot.* = .{
                .active = true,
                .service_id = service_id,
                .port = parsed.port,
                .state = .disconnected,
            };
            @memcpy(slot.host[0..parsed.host.len], parsed.host);
            slot.host_len = parsed.host.len;
            return @intCast(i);
        }
    }
    core.setError("connector: pool exhausted ({d})", .{MAX_CONNECTORS});
    return 255;
}

pub export fn uapi_connector_destroy(slot_idx: u8) callconv(.c) void {
    if (slot_idx >= MAX_CONNECTORS) return;
    pool_mutex.lock();
    defer pool_mutex.unlock();
    pool[slot_idx] = .{};
}

pub export fn uapi_connector_state(slot_idx: u8) callconv(.c) u8 {
    if (slot_idx >= MAX_CONNECTORS) return @intFromEnum(core.ConnectorState.failed);
    pool_mutex.lock();
    defer pool_mutex.unlock();
    if (!pool[slot_idx].active) return @intFromEnum(core.ConnectorState.disconnected);
    return @intFromEnum(pool[slot_idx].state);
}

pub export fn uapi_connector_health(slot_idx: u8) callconv(.c) u8 {
    if (slot_idx >= MAX_CONNECTORS) return @intFromEnum(core.ConnectorState.failed);
    var path_buf: [16]u8 = undefined;
    @memcpy(path_buf[0.."/health".len], "/health");
    var out: [256]u8 = undefined;
    const rc = uapi_connector_call(slot_idx, 0, @ptrCast(&path_buf), "", &out, out.len);
    return if (rc == core.Result.ok.toU8())
        @intFromEnum(core.ConnectorState.connected)
    else
        @intFromEnum(core.ConnectorState.failed);
}

pub export fn uapi_connector_call(
    slot_idx: u8,
    method_tag: u8,
    path_ptr: ?[*:0]const u8,
    body_ptr: ?[*:0]const u8,
    out_buf: ?[*]u8,
    out_len: u32,
) callconv(.c) u8 {
    if (slot_idx >= MAX_CONNECTORS or method_tag > 6) {
        return core.Result.invalid_param.toU8();
    }
    const path = std.mem.span(path_ptr orelse return core.Result.null_pointer.toU8());
    const body = if (body_ptr) |bp| std.mem.span(bp) else "";
    const dest = out_buf orelse return core.Result.null_pointer.toU8();
    if (out_len == 0) return core.Result.invalid_param.toU8();

    pool_mutex.lock();
    const host_len = pool[slot_idx].host_len;
    var host_copy: [MAX_URL_LEN]u8 = undefined;
    @memcpy(host_copy[0..host_len], pool[slot_idx].host[0..host_len]);
    const port = pool[slot_idx].port;
    pool_mutex.unlock();
    const host = host_copy[0..host_len];

    const method: core.HttpMethod = @enumFromInt(method_tag);

    const ok = httpRoundTrip(host, port, method, path, body, dest[0..out_len]);
    if (ok) {
        pool_mutex.lock();
        if (pool[slot_idx].active) {
            pool[slot_idx].state = .connected;
            pool[slot_idx].requests_ok += 1;
        }
        pool_mutex.unlock();
        return core.Result.ok.toU8();
    }
    pool_mutex.lock();
    if (pool[slot_idx].active) {
        pool[slot_idx].state = .failed;
        pool[slot_idx].requests_err += 1;
    }
    pool_mutex.unlock();
    return core.Result.process_failed.toU8();
}

// ---------------------------------------------------------------------------
// HTTP/1.1 client
// ---------------------------------------------------------------------------

fn setStreamTimeouts(stream: std.net.Stream, seconds: u32) void {
    const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
    const bytes = std.mem.asBytes(&tv);
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes) catch {};
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes) catch {};
}

fn readLine(stream: std.net.Stream, buf: []u8) ![]u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        var one: [1]u8 = undefined;
        const n = try stream.read(&one);
        if (n == 0) break;
        if (one[0] == '\n') {
            const end = if (pos > 0 and buf[pos - 1] == '\r') pos - 1 else pos;
            return buf[0..end];
        }
        buf[pos] = one[0];
        pos += 1;
    }
    return error.EndOfStream;
}

/// One HTTP/1.1 round-trip. Copies the response body into `dest`
/// (truncating to dest.len-1) and null-terminates. Returns false on any
/// transport error.
fn httpRoundTrip(
    host: []const u8,
    port: u16,
    method: core.HttpMethod,
    path: []const u8,
    body: []const u8,
    dest: []u8,
) bool {
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const stream = std.net.tcpConnectToHost(arena, host, port) catch return false;
    defer stream.close();
    setStreamTimeouts(stream, IO_TIMEOUT_S);

    // --- Request ------------------------------------------------------------
    var req_buf: [4096]u8 = undefined;
    const req = std.fmt.bufPrint(
        &req_buf,
        "{s} {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{ method.text(), path, host, body.len },
    ) catch return false;
    stream.writeAll(req) catch return false;
    if (body.len > 0) stream.writeAll(body) catch return false;

    // --- Status line (parse but do not gate on the code) -------------------
    var line_buf: [4096]u8 = undefined;
    const status_line = readLine(stream, &line_buf) catch return false;
    _ = status_line;

    // --- Headers ------------------------------------------------------------
    var content_length: ?usize = null;
    while (true) {
        const line = readLine(stream, &line_buf) catch return false;
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const v = std.mem.trim(u8, line["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, v, 10) catch null;
        }
    }

    // --- Body ----------------------------------------------------------------
    // The read cap is 4 MiB — heap, not stack.
    const body_buf = arena.alloc(u8, MAX_RESPONSE_BYTES) catch return false;
    var got: usize = 0;
    if (content_length) |cl| {
        const want = @min(cl, body_buf.len);
        while (got < want) {
            const n = stream.read(body_buf[got..want]) catch break;
            if (n == 0) break;
            got += n;
        }
    } else {
        // No Content-Length: read to EOF (Connection: close).
        while (got < body_buf.len) {
            const n = stream.read(body_buf[got..]) catch break;
            if (n == 0) break;
            got += n;
        }
    }

    // Copy out, null-terminate, truncate as documented.
    const n_copy = @min(got, dest.len - 1);
    @memcpy(dest[0..n_copy], body_buf[0..n_copy]);
    dest[n_copy] = 0;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "connector: base_url parsing" {
    const ok1 = parseBaseUrl("http://librespeed:8080").?;
    try std.testing.expectEqualStrings("librespeed", ok1.host);
    try std.testing.expectEqual(@as(u16, 8080), ok1.port);

    const ok2 = parseBaseUrl("http://hyperglass/").?;
    try std.testing.expectEqualStrings("hyperglass", ok2.host);
    try std.testing.expectEqual(@as(u16, 80), ok2.port);

    try std.testing.expect(parseBaseUrl("https://x") == null);
    try std.testing.expect(parseBaseUrl("http://") == null);
    try std.testing.expect(parseBaseUrl("ftp://h") == null);
    try std.testing.expect(parseBaseUrl("http://u:p@h") == null);
}

test "connector: create/destroy/state lifecycle" {
    const url: [*:0]const u8 = "http://127.0.0.1:1"; // port 1: nothing listens
    const slot = uapi_connector_create(0, url);
    try std.testing.expect(slot != 255);
    defer uapi_connector_destroy(slot);

    try std.testing.expectEqual(@as(u8, 0), uapi_connector_state(slot)); // disconnected

    var out: [64]u8 = undefined;
    const path: [*:0]const u8 = "/";
    const rc = uapi_connector_call(slot, 0, path, "", &out, out.len);
    try std.testing.expectEqual(@as(u8, 6), rc); // process_failed: transport
    try std.testing.expectEqual(@as(u8, 4), uapi_connector_state(slot)); // failed

    uapi_connector_destroy(slot);
    try std.testing.expectEqual(@as(u8, 0), uapi_connector_state(slot)); // disconnected
}

test "connector: invalid args" {
    var out: [8]u8 = undefined;
    const path: [*:0]const u8 = "/";
    try std.testing.expectEqual(@as(u8, 255), uapi_connector_create(0, null));
    try std.testing.expectEqual(@as(u8, 2), uapi_connector_call(200, 0, path, null, &out, 8)); // invalid slot
    try std.testing.expectEqual(@as(u8, 2), uapi_connector_call(0, 99, path, null, &out, 8)); // invalid method
}
