// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// gnosis.zig — in-repo gnosis server pool: a small, correct, threaded
// HTTP/1.1 edge server behind the uapi_gnosis_* C ABI (declared in
// src/abi/Gnosis.idr, header ffi/zig/include/zig_api.h).
//
// Superset-compatible with developer-ecosystem/zig-api (same symbols, tags
// and v1 layouts); the estate library may replace this file wholesale.
//
// Deliberate scope (prototype phase): origin-form requests, Content-Length
// bodies (no chunked), Connection: close on every response, thread-per-
// connection with a hard concurrency cap, socket read timeouts. No TLS —
// TLS terminates at the reverse proxy, as in the compose topology.
//
// V2 (aerie extension): handlers registered via uapi_gnosis_set_handler_v2
// receive the raw query string and every request header, fixing the v1
// information loss that starved the policy gate (X-Api-Key) and the
// resolvers (query parameters).

const std = @import("std");
const core = @import("core.zig");

// ---------------------------------------------------------------------------
// Wire types (must match zig_api.h exactly; asserted by tests below)
// ---------------------------------------------------------------------------

pub const GnosisRequest = extern struct {
    method:   [*:0]const u8,
    path:     [*:0]const u8,
    body_ptr: ?[*]const u8,
    body_len: u32,
};

pub const GnosisRequestV2 = extern struct {
    method:       [*:0]const u8,
    path:         [*:0]const u8,
    query:        [*:0]const u8,
    body_ptr:     ?[*]const u8,
    body_len:     u32,
    header_names: ?[*]const ?[*:0]const u8,
    header_values: ?[*]const ?[*:0]const u8,
    header_count: u32,
    resp_scratch: ?[*]u8,
    resp_scratch_len: u32,
};

pub const GnosisResponse = extern struct {
    status:       u16,
    _pad:         u16 = 0,
    content_type: ?[*:0]const u8,
    body_ptr:     ?[*]const u8,
    body_len:     u32,
};

pub const HandlerFn = *const fn ([*c]const GnosisRequest, [*c]GnosisResponse) callconv(.c) void;
pub const HandlerFnV2 = *const fn ([*c]const GnosisRequestV2, [*c]GnosisResponse) callconv(.c) void;

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

const MAX_SERVERS: usize = 16;
const MAX_CONNECTIONS: u32 = 64;          // concurrent connection cap
const MAX_HEADER_BYTES: usize = 16 * 1024; // header block cap
const MAX_BODY_BYTES: usize = 1 << 20;   // 1 MiB
const MAX_HEADERS: usize = 64;
const RESP_SCRATCH_BYTES: usize = 128 * 1024; // per-connection response scratch
const READ_TIMEOUT_S: u32 = 10;
const BACKLOG: u32 = 128;

// ---------------------------------------------------------------------------
// Server pool
// ---------------------------------------------------------------------------

const Server = struct {
    port: u16,
    handler: ?HandlerFn = null,
    handler_v2: ?HandlerFnV2 = null,
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(core.ServerState.idle)),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    listener: ?std.net.Server = null,
    active_conns: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

var servers: [MAX_SERVERS]?*Server = [1]?*Server{null} ** MAX_SERVERS;
var servers_mutex: std.Thread.Mutex = .{};
var lib_alloc: std.mem.Allocator = std.heap.c_allocator;

/// Handle scheme: slot index + 1, so 0 stays "failure".
fn handleFromSlot(slot: usize) u64 {
    return @intCast(slot + 1);
}

fn slotFromHandle(handle: u64) ?usize {
    if (handle == 0 or handle > MAX_SERVERS) return null;
    return @intCast(handle - 1);
}

// ---------------------------------------------------------------------------
// C ABI — gnosis lifecycle
// ---------------------------------------------------------------------------

pub export fn uapi_gnosis_create(port: u16) callconv(.c) u64 {
    servers_mutex.lock();
    defer servers_mutex.unlock();
    for (&servers, 0..) |*slot, i| {
        if (slot.* == null) {
            const srv = lib_alloc.create(Server) catch {
                core.setError("gnosis: alloc failed", .{});
                return 0;
            };
            srv.* = .{ .port = port };
            slot.* = srv;
            return handleFromSlot(i);
        }
    }
    core.setError("gnosis: pool exhausted ({d} slots)", .{MAX_SERVERS});
    return 0;
}

pub export fn uapi_gnosis_set_handler(
    handle: u64,
    handler_fn: ?HandlerFn,
) callconv(.c) u8 {
    servers_mutex.lock();
    defer servers_mutex.unlock();
    const slot = slotFromHandle(handle) orelse return core.Result.invalid_param.toU8();
    const srv = servers[slot] orelse return core.Result.invalid_param.toU8();
    if (srv.state.load(.acquire) == @intFromEnum(core.ServerState.listening)) {
        return core.Result.err.toU8(); // no hot-swap, per ABI contract
    }
    srv.handler = handler_fn;
    return core.Result.ok.toU8();
}

pub export fn uapi_gnosis_set_handler_v2(
    handle: u64,
    handler_fn: ?HandlerFnV2,
) callconv(.c) u8 {
    servers_mutex.lock();
    defer servers_mutex.unlock();
    const slot = slotFromHandle(handle) orelse return core.Result.invalid_param.toU8();
    const srv = servers[slot] orelse return core.Result.invalid_param.toU8();
    if (srv.state.load(.acquire) == @intFromEnum(core.ServerState.listening)) {
        return core.Result.err.toU8();
    }
    srv.handler_v2 = handler_fn;
    return core.Result.ok.toU8();
}

pub export fn uapi_gnosis_start(handle: u64) callconv(.c) u8 {
    servers_mutex.lock();
    const slot = slotFromHandle(handle) orelse {
        servers_mutex.unlock();
        return core.Result.invalid_param.toU8();
    };
    const srv = servers[slot] orelse {
        servers_mutex.unlock();
        return core.Result.invalid_param.toU8();
    };

    // Idempotent when already listening.
    if (srv.state.load(.acquire) == @intFromEnum(core.ServerState.listening)) {
        servers_mutex.unlock();
        return core.Result.ok.toU8();
    }
    if (srv.state.load(.acquire) == @intFromEnum(core.ServerState.draining)) {
        servers_mutex.unlock();
        return core.Result.err.toU8();
    }

    // Bind (first start, or re-bind after a stop closed the listener).
    if (srv.listener == null) {
        const addr = std.net.Address.parseIp("0.0.0.0", srv.port) catch {
            servers_mutex.unlock();
            core.setError("gnosis: bad bind address", .{});
            return core.Result.invalid_param.toU8();
        };
        srv.listener = addr.listen(.{ .reuse_address = true, .kernel_backlog = BACKLOG }) catch |e| {
            servers_mutex.unlock();
            core.setError("gnosis: bind :{d} failed ({})", .{ srv.port, e });
            return core.Result.err.toU8();
        };
    }

    srv.running.store(true, .release);
    srv.state.store(@intFromEnum(core.ServerState.listening), .release);
    const bound_listener = srv.listener.?;
    servers_mutex.unlock();

    // Serve on the current thread? No — spawn, per ABI ("background thread").
    srv.thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, serveLoop, .{ srv, bound_listener }) catch {
        srv.running.store(false, .release);
        srv.state.store(@intFromEnum(core.ServerState.stopped), .release);
        core.setError("gnosis: thread spawn failed", .{});
        return core.Result.err.toU8();
    };
    return core.Result.ok.toU8();
}

pub export fn uapi_gnosis_stop(handle: u64) callconv(.c) void {
    servers_mutex.lock();
    const slot = slotFromHandle(handle) orelse {
        servers_mutex.unlock();
        return;
    };
    const srv = servers[slot] orelse {
        servers_mutex.unlock();
        return;
    };
    servers_mutex.unlock();

    srv.state.store(@intFromEnum(core.ServerState.draining), .release);
    srv.running.store(false, .release);

    // Closing the listener forces accept() to return; the loop then exits.
    if (srv.listener) |*l| {
        var stale = l.*;
        srv.listener = null;
        stale.deinit();
    }

    if (srv.thread) |t| {
        t.join();
        srv.thread = null;
    }
    srv.state.store(@intFromEnum(core.ServerState.stopped), .release);
}

pub export fn uapi_gnosis_destroy(handle: u64) callconv(.c) void {
    servers_mutex.lock();
    const slot = slotFromHandle(handle) orelse {
        servers_mutex.unlock();
        return;
    };
    const srv = servers[slot] orelse {
        servers_mutex.unlock();
        return;
    };
    servers[slot] = null;
    servers_mutex.unlock();

    if (srv.state.load(.acquire) != @intFromEnum(core.ServerState.stopped)) {
        uapi_gnosis_stop(handle);
    }
    lib_alloc.destroy(srv);
}

pub export fn uapi_gnosis_state(handle: u64) callconv(.c) u8 {
    servers_mutex.lock();
    defer servers_mutex.unlock();
    const slot = slotFromHandle(handle) orelse return @intFromEnum(core.ServerState.stopped);
    const srv = servers[slot] orelse return @intFromEnum(core.ServerState.stopped);
    return srv.state.load(.acquire);
}

pub export fn uapi_gnosis_health(handle: u64) callconv(.c) u8 {
    const st = uapi_gnosis_state(handle);
    return if (st == @intFromEnum(core.ServerState.listening)) 0 else 1;
}

pub export fn uapi_gnosis_write_response(
    resp: [*c]GnosisResponse,
    status: u16,
    content_type: ?[*:0]const u8,
    body_ptr: ?[*]const u8,
    body_len: u32,
) callconv(.c) void {
    const r: *GnosisResponse = @ptrCast(resp);
    r.status = status;
    r._pad = 0;
    r.content_type = content_type;
    r.body_ptr = body_ptr;
    r.body_len = body_len;
}

// ---------------------------------------------------------------------------
// Serve loop + per-connection handling
// ---------------------------------------------------------------------------

fn serveLoop(srv: *Server, listener_in: std.net.Server) void {
    // Owned copy of the listener (same fd). stop() closes the fd through
    // its own copy to unblock accept(); this side never deinit()s.
    var listener = listener_in;
    while (srv.running.load(.acquire)) {
        const conn = listener.accept() catch break;
        if (srv.active_conns.load(.monotonic) >= MAX_CONNECTIONS) {
            conn.stream.close();
            continue;
        }
        _ = srv.active_conns.fetchAdd(1, .acq_rel);
        const t = std.Thread.spawn(.{ .stack_size = 1 << 20 }, handleConn, .{ srv, conn }) catch {
            _ = srv.active_conns.fetchSub(1, .acq_rel);
            conn.stream.close();
            continue;
        };
        t.detach();
    }
    // Listener ownership: stop() closes it to unblock accept(). If the
    // loop exited on its own (accept error), keep the fd for a restart
    // but reflect the honest state.
    if (srv.running.load(.acquire)) {
        srv.state.store(@intFromEnum(core.ServerState.stopped), .release);
    }
}

fn setStreamTimeouts(stream: std.net.Stream, seconds: u32) void {
    const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
    const bytes = std.mem.asBytes(&tv);
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes) catch {};
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes) catch {};
}

/// One parsed request, with all storage in this frame.
const ParsedRequest = struct {
    method_buf: [16]u8 = undefined,
    method_len: usize = 0,
    path_buf: [1024]u8 = undefined,
    path_len: usize = 0,     // query-stripped
    query_buf: [2048]u8 = undefined,
    query_len: usize = 0,    // raw query, no '?'
    headers: [MAX_HEADERS]Header = undefined,
    header_count: usize = 0,
    body_buf: [MAX_BODY_BYTES]u8 = undefined,
    body_len: usize = 0,

    const Header = struct {
        name_buf: [128]u8 = undefined,
        name_len: usize = 0,
        value_buf: [512]u8 = undefined,
        value_len: usize = 0,
    };
};

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
    return buf[0..pos];
}

fn handleConn(srv: *Server, conn: std.net.Server.Connection) void {
    defer _ = srv.active_conns.fetchSub(1, .acq_rel);
    defer conn.stream.close();
    setStreamTimeouts(conn.stream, READ_TIMEOUT_S);

    // ParsedRequest carries ~1.1 MiB of fixed buffers (1 MiB body cap) —
    // far beyond a sane thread stack, so it lives on the heap.
    const req = lib_alloc.create(ParsedRequest) catch return;
    defer lib_alloc.destroy(req);
    req.* = .{};
    var line_buf: [4096]u8 = undefined;

    // --- Request line -----------------------------------------------------
    const req_line = readLine(conn.stream, &line_buf) catch return;
    var parts = std.mem.splitScalar(u8, req_line, ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    if (method.len >= req.method_buf.len or target.len >= req.path_buf.len + req.query_buf.len) return;

    @memcpy(req.method_buf[0..method.len], method);
    req.method_len = method.len;

    // Split target into path + query.
    const q_idx = std.mem.indexOfScalar(u8, target, '?');
    const raw_path = if (q_idx) |qi| target[0..qi] else target;
    const raw_query = if (q_idx) |qi| target[qi + 1 ..] else "";
    if (raw_path.len >= req.path_buf.len or raw_query.len >= req.query_buf.len) return;
    @memcpy(req.path_buf[0..raw_path.len], raw_path);
    req.path_len = raw_path.len;
    @memcpy(req.query_buf[0..raw_query.len], raw_query);
    req.query_len = raw_query.len;

    // --- Headers ------------------------------------------------------------
    var header_bytes: usize = 0;
    var content_length: usize = 0;
    while (true) {
        const line = readLine(conn.stream, &line_buf) catch break;
        if (line.len == 0) break; // end of headers
        header_bytes += line.len;
        if (header_bytes > MAX_HEADER_BYTES) return;

        if (req.header_count < MAX_HEADERS) {
            const h = &req.headers[req.header_count];
            if (std.mem.indexOfScalar(u8, line, ':')) |ci| {
                const name = std.mem.trim(u8, line[0..ci], " \t");
                const value = std.mem.trim(u8, line[ci + 1 ..], " \t");
                if (name.len < h.name_buf.len and value.len < h.value_buf.len) {
                    @memcpy(h.name_buf[0..name.len], name);
                    h.name_len = name.len;
                    @memcpy(h.value_buf[0..value.len], value);
                    h.value_len = value.len;
                    req.header_count += 1;
                }
            }
        }
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const v = std.mem.trim(u8, line["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, v, 10) catch 0;
        }
    }

    // --- Body ---------------------------------------------------------------
    if (content_length > 0) {
        if (content_length > MAX_BODY_BYTES) content_length = MAX_BODY_BYTES;
        var got: usize = 0;
        while (got < content_length) {
            const n = conn.stream.read(req.body_buf[got..content_length]) catch break;
            if (n == 0) break;
            got += n;
        }
        req.body_len = got;
    }

    // --- Dispatch to the registered handler --------------------------------
    // Method/path/query need null-termination for the C ABI; the fixed
    // buffers have room because the lengths were bounds-checked on entry.
    req.method_buf[req.method_len] = 0;
    req.path_buf[req.path_len] = 0;
    req.query_buf[req.query_len] = 0;
    for (req.headers[0..req.header_count]) |*h| {
        h.name_buf[h.name_len] = 0;
        h.value_buf[h.value_len] = 0;
    }

    var resp: GnosisResponse = .{
        .status = 500,
        .content_type = null,
        .body_ptr = null,
        .body_len = 0,
    };

    // Response scratch: gnosis-owned, outlives the handler call, freed
    // after the socket write (function scope — a block-scoped defer would
    // free it before writeGnosisResponse, the exact bug class this buffer
    // exists to prevent).
    const scratch = lib_alloc.alloc(u8, RESP_SCRATCH_BYTES) catch null;
    defer if (scratch) |sc| lib_alloc.free(sc);

    if (srv.handler_v2) |h2| {
        var names: [MAX_HEADERS]?[*:0]const u8 = undefined;
        var values: [MAX_HEADERS]?[*:0]const u8 = undefined;
        for (req.headers[0..req.header_count], 0..) |*h, i| {
            names[i] = @ptrCast(&h.name_buf);
            values[i] = @ptrCast(&h.value_buf);
        }
        const v2 = GnosisRequestV2{
            .method = @ptrCast(&req.method_buf),
            .path = @ptrCast(&req.path_buf),
            .query = @ptrCast(&req.query_buf),
            .body_ptr = if (req.body_len > 0) @ptrCast(&req.body_buf) else null,
            .body_len = @intCast(req.body_len),
            .header_names = if (req.header_count > 0) &names else null,
            .header_values = if (req.header_count > 0) &values else null,
            .header_count = @intCast(req.header_count),
            .resp_scratch = if (scratch) |sc| sc.ptr else null,
            .resp_scratch_len = if (scratch) |sc| @intCast(sc.len) else 0,
        };
        h2(&v2, &resp);
    } else if (srv.handler) |h1| {
        const v1 = GnosisRequest{
            .method = @ptrCast(&req.method_buf),
            .path = @ptrCast(&req.path_buf),
            .body_ptr = if (req.body_len > 0) @ptrCast(&req.body_buf) else null,
            .body_len = @intCast(req.body_len),
        };
        h1(&v1, &resp);
    } else {
        resp.status = 503;
        resp.content_type = "application/json";
        resp.body_ptr = "{\"error\":\"no handler registered\"}";
        resp.body_len = 31;
    }

    writeGnosisResponse(conn.stream, &resp);
}

fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Response",
    };
}

fn writeGnosisResponse(stream: std.net.Stream, resp: *const GnosisResponse) void {
    var head_buf: [512]u8 = undefined;
    const ct: []const u8 = if (resp.content_type) |p| std.mem.span(p) else "application/json";
    const body: []const u8 = if (resp.body_ptr) |p| p[0..resp.body_len] else "";
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{ resp.status, reasonPhrase(resp.status), ct, body.len },
    ) catch return;
    stream.writeAll(head) catch {};
    if (body.len > 0) stream.writeAll(body) catch {};
}

// ---------------------------------------------------------------------------
// Tests — including the ABI layout assertion against zig_api.h
// ---------------------------------------------------------------------------

test "gnosis: v1/v2 wire structs match zig_api.h layout" {
    const h = @cImport({
        @cInclude("zig_api.h");
    });
    try std.testing.expectEqual(@sizeOf(h.GnosisRequest), @sizeOf(GnosisRequest));
    try std.testing.expectEqual(@offsetOf(h.GnosisRequest, "body_len"), @offsetOf(GnosisRequest, "body_len"));
    try std.testing.expectEqual(@sizeOf(h.GnosisRequestV2), @sizeOf(GnosisRequestV2));
    try std.testing.expectEqual(@offsetOf(h.GnosisRequestV2, "header_count"), @offsetOf(GnosisRequestV2, "header_count"));
    try std.testing.expectEqual(@offsetOf(h.GnosisRequestV2, "resp_scratch"), @offsetOf(GnosisRequestV2, "resp_scratch"));
    try std.testing.expectEqual(@offsetOf(h.GnosisRequestV2, "resp_scratch_len"), @offsetOf(GnosisRequestV2, "resp_scratch_len"));
    try std.testing.expectEqual(@sizeOf(h.GnosisResponse), @sizeOf(GnosisResponse));
    try std.testing.expectEqual(@offsetOf(h.GnosisResponse, "body_len"), @offsetOf(GnosisResponse, "body_len"));
}

test "gnosis: create/start/stop/destroy lifecycle" {
    const handle = uapi_gnosis_create(0); // port 0: OS-assigned
    try std.testing.expect(handle != 0);
    defer uapi_gnosis_destroy(handle);

    const H = struct {
        fn handler(req: [*c]const GnosisRequest, resp: [*c]GnosisResponse) callconv(.c) void {
            _ = req;
            resp.*.status = 200;
            resp.*.content_type = "application/json";
            resp.*.body_ptr = "{\"ok\":true}";
            resp.*.body_len = 10;
        }
    };
    try std.testing.expectEqual(@as(u8, 0), uapi_gnosis_set_handler(handle, H.handler));

    // Port 0 cannot be dialed externally; start still must reach LISTENING.
    try std.testing.expectEqual(@as(u8, 0), uapi_gnosis_start(handle));
    try std.testing.expectEqual(@as(u8, 1), uapi_gnosis_state(handle)); // listening
    // Idempotent start.
    try std.testing.expectEqual(@as(u8, 0), uapi_gnosis_start(handle));
    uapi_gnosis_stop(handle);
    try std.testing.expectEqual(@as(u8, 3), uapi_gnosis_state(handle)); // stopped
}

test "gnosis: handle validation" {
    try std.testing.expectEqual(@as(u8, 3), uapi_gnosis_state(0)); // stopped
    try std.testing.expectEqual(@as(u8, 2), uapi_gnosis_set_handler(9999, null)); // invalid_param
}
