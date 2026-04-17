// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// verisim_client.zig — VerisimDB Bitemporal Client for Forensic Audit Storage
//
// Provides bitemporal storage for audit events via VerisimDB's HTTP REST API.
//
// Fire-and-forget: all errors are logged to stderr and swallowed. The gateway
// never blocks on VerisimDB unavailability — Redis remains the primary log.
//
// Replaces: verisim_client.v

const std  = @import("std");
const t    = @import("types.zig");
const rc   = @import("redis_client.zig");
const ls   = @import("librespeed_client.zig");

/// Serialise an AuditEvent to JSON. Shared with redis_client and verisim_client.
pub fn auditEventToJson(ev: t.AuditEvent, buf: []u8) ![]const u8 {
    var tags_buf: [256]u8 = undefined;
    var tfbs = std.io.fixedBufferStream(&tags_buf);
    const tw = tfbs.writer();
    try tw.writeByte('[');
    var i: usize = 0;
    while (i < ev.tag_count) : (i += 1) {
        if (i > 0) try tw.writeByte(',');
        try tw.writeByte('"');
        try tw.writeAll(std.mem.sliceTo(&ev.tags[i], 0));
        try tw.writeByte('"');
    }
    try tw.writeByte(']');
    const tags_json = tfbs.getWritten();

    return try std.fmt.bufPrint(buf,
        "{{\"event_id\":\"{s}\",\"valid_time\":\"{s}\",\"tx_time\":\"{s}\"," ++
        "\"severity\":\"{s}\",\"message\":\"{s}\",\"tags\":{s}}}",
        .{
            std.mem.sliceTo(&ev.event_id,  0),
            std.mem.sliceTo(&ev.valid_time, 0),
            std.mem.sliceTo(&ev.tx_time,   0),
            std.mem.sliceTo(&ev.severity,  0),
            std.mem.sliceTo(&ev.message,   0),
            tags_json,
        },
    );
}

pub const VerisimDBClient = struct {
    base_url:     [256]u8,
    base_url_len: usize,

    /// Build from VERISIMDB_URL env var (default http://verisimdb:8084).
    pub fn init() VerisimDBClient {
        var c: VerisimDBClient = std.mem.zeroes(VerisimDBClient);
        const def = "http://verisimdb:8084";
        var url: []const u8 = def;
        var local_buf: [256]u8 = undefined;
        if (std.posix.getenv("VERISIMDB_URL")) |env_url| {
            // Strip trailing slash
            const stripped = if (std.mem.endsWith(u8, env_url, "/"))
                env_url[0..env_url.len - 1]
            else env_url;
            const n = @min(stripped.len, 255);
            @memcpy(local_buf[0..n], stripped[0..n]);
            local_buf[n] = 0;
            url = local_buf[0..n];
        }
        const n = @min(url.len, 255);
        @memcpy(c.base_url[0..n], url[0..n]);
        c.base_url[n]     = 0;
        c.base_url_len    = n;
        return c;
    }

    fn baseUrl(self: *const VerisimDBClient) []const u8 {
        return self.base_url[0..self.base_url_len];
    }

    /// POST a JSON audit event to /api/v1/events. Fire-and-forget.
    pub fn storeAudit(self: *const VerisimDBClient, ev: t.AuditEvent) void {
        var json_buf: [512]u8 = undefined;
        const event_json = auditEventToJson(ev, &json_buf) catch {
            std.debug.print("[aerie] verisimdb: storeAudit serialise failed\n", .{});
            return;
        };

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/api/v1/events", .{self.baseUrl()})
            catch return;

        httpPost(url, event_json) catch |err| {
            std.debug.print("[aerie] verisimdb: storeAudit failed ({s}): {s}\n",
                .{ self.baseUrl(), @errorName(err) });
        };
    }

    /// Query events as they were at `as_of_time` (RFC 3339).
    /// Appends JSON-string events to `out_list` (duped into `arena`).
    pub fn queryAsOf(
        self:       *const VerisimDBClient,
        as_of_time: []const u8,
        limit:      u32,
        out_list:   *std.ArrayList([]const u8),
        arena:      std.mem.Allocator,
    ) void {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf,
            "{s}/api/v1/events?as_of={s}&limit={d}",
            .{ self.baseUrl(), as_of_time, limit },
        ) catch return;
        fetchAndParse(url, out_list, arena);
    }

    /// Query events with valid_time in [start, end].
    pub fn queryBetween(
        self:     *const VerisimDBClient,
        start:    []const u8,
        end:      []const u8,
        limit:    u32,
        out_list: *std.ArrayList([]const u8),
        arena:    std.mem.Allocator,
    ) void {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf,
            "{s}/api/v1/events?start={s}&end={s}&limit={d}",
            .{ self.baseUrl(), start, end, limit },
        ) catch return;
        fetchAndParse(url, out_list, arena);
    }

    /// Query full bitemporal history of a single event by UUID.
    pub fn queryHistory(
        self:     *const VerisimDBClient,
        event_id: []const u8,
        out_list: *std.ArrayList([]const u8),
        arena:    std.mem.Allocator,
    ) void {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf,
            "{s}/api/v1/events/{s}/history",
            .{ self.baseUrl(), event_id },
        ) catch return;
        fetchAndParse(url, out_list, arena);
    }
};

/// HTTP GET a URL and parse the {"events":[...]} response.
fn fetchAndParse(
    url:      []const u8,
    out_list: *std.ArrayList([]const u8),
    arena:    std.mem.Allocator,
) void {
    var body_buf: [65536]u8 = undefined;
    const body = ls.httpGet(url, &body_buf) catch |err| {
        std.debug.print("[aerie] verisimdb: GET {s} failed: {s}\n",
            .{ url, @errorName(err) });
        return;
    };
    parseVerisimDBResponse(body, out_list, arena);
}

/// Parse {"events":[...]} response. On parse failure, push the raw body
/// as a single element (graceful degradation).
fn parseVerisimDBResponse(
    body:     []const u8,
    out_list: *std.ArrayList([]const u8),
    arena:    std.mem.Allocator,
) void {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return;

    // Look for "events": [...]
    const events_needle = "\"events\"";
    const events_pos = std.mem.indexOf(u8, trimmed, events_needle) orelse {
        // No "events" key — push the raw body as-is
        const owned = arena.dupe(u8, trimmed) catch return;
        out_list.append(arena, owned) catch {};
        return;
    };

    // Find the opening bracket after "events"
    const after = trimmed[events_pos + events_needle.len ..];
    const bracket_pos = std.mem.indexOfScalar(u8, after, '[') orelse {
        const owned = arena.dupe(u8, trimmed) catch return;
        out_list.append(arena, owned) catch {};
        return;
    };

    // Extract each {...} object from the array
    var pos: usize = bracket_pos + 1;
    const arr = after;
    while (pos < arr.len) {
        const obj_start = std.mem.indexOfScalarPos(u8, arr, pos, '{') orelse break;
        const obj_end   = findMatchingBrace(arr, obj_start) orelse break;
        const obj = arr[obj_start .. obj_end + 1];
        const owned = arena.dupe(u8, obj) catch break;
        out_list.append(arena, owned) catch break;
        pos = obj_end + 1;
    }
}

/// Find the matching closing brace for an opening brace at `start`.
fn findMatchingBrace(data: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i: usize = start;
    while (i < data.len) {
        switch (data[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

/// HTTP POST: send `body` to `url`, ignore the response.
fn httpPost(url: []const u8, body: []const u8) !void {
    const without_scheme = if (std.mem.startsWith(u8, url, "http://"))
        url[7..]
    else
        return error.UnsupportedScheme;

    const slash = std.mem.indexOfScalar(u8, without_scheme, '/') orelse without_scheme.len;
    const host_port = without_scheme[0..slash];
    const path: []const u8 = if (slash < without_scheme.len) without_scheme[slash..] else "/";

    var host_buf: [128]u8 = undefined;
    var port: u16 = 80;
    if (std.mem.indexOfScalar(u8, host_port, ':')) |ci| {
        const h = host_port[0..ci];
        @memcpy(host_buf[0..h.len], h);
        host_buf[h.len] = 0;
        port = std.fmt.parseInt(u16, host_port[ci + 1 ..], 10) catch 80;
    } else {
        @memcpy(host_buf[0..host_port.len], host_port);
        host_buf[host_port.len] = 0;
    }
    const host_str = host_buf[0..host_port.len];

    const addr = std.net.Address.resolveIp(host_str, port) catch
        try std.net.Address.parseIp4(host_str, port);
    const stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    var hdr_buf: [512]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf,
        "POST {s} HTTP/1.0\r\nHost: {s}\r\nContent-Type: application/json\r\n" ++
        "Content-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ path, host_str, body.len },
    );
    try stream.writeAll(hdr);
    try stream.writeAll(body);
    // Read and discard response
    var discard: [256]u8 = undefined;
    _ = stream.read(&discard) catch {};
}

/// Dual-log: write audit event to both Redis and VerisimDB.
/// Redis write is synchronous; VerisimDB is fire-and-forget.
pub fn dualLogAudit(
    redis:     *rc.RedisClient,
    verisimdb: *const VerisimDBClient,
    ev:        t.AuditEvent,
) void {
    redis.logAudit(ev);
    verisimdb.storeAudit(ev);
}
