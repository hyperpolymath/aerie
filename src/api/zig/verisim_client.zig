// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// verisim_client.zig — VerisimDB Bitemporal Client for Forensic Audit Storage
//
// Provides bitemporal storage for audit events via VerisimDB's HTTP REST API.
//
// Fire-and-forget: all errors are logged to stderr and swallowed. The gateway
// never blocks on VerisimDB unavailability — Redis remains the primary log.
//
// Transport layer: uapi_connector_* (developer-ecosystem/zig-api) — replaces
// the hand-rolled std.net.tcpConnectToAddress httpPost and the delegation to
// librespeed_client.httpGet for fetches.  VerisimDB now has its own persistent
// connector slot so its pool lifecycle is independent of librespeed.
//
// Replaces: verisim_client.v

const std  = @import("std");
const t    = @import("types.zig");
const rc   = @import("redis_client.zig");

/// C ABI imports from libzig_api.
const c = @cImport({
    @cInclude("zig_api.h");
});

// ---------------------------------------------------------------------------
// Connector slot (lazily initialised, module-level)
// ---------------------------------------------------------------------------

/// UAPI_SERVICE_VERISIMDB is the canonical service-id for VerisimDB.
const VERISIMDB_SERVICE_ID: u8 = c.UAPI_SERVICE_VERISIMDB;

var connector_slot: u8 = 255;

var base_url_buf: [256]u8 = undefined;
var base_url_len: usize   = 0;
var base_url_init: bool   = false;

fn ensureBaseUrl() []const u8 {
    if (base_url_init) return base_url_buf[0..base_url_len];
    const def = "http://verisimdb:8084";
    if (std.posix.getenv("VERISIMDB_URL")) |url| {
        // Strip trailing slash
        const stripped = if (std.mem.endsWith(u8, url, "/"))
            url[0..url.len - 1]
        else url;
        const n = @min(stripped.len, base_url_buf.len - 1);
        @memcpy(base_url_buf[0..n], stripped[0..n]);
        base_url_buf[n] = 0;
        base_url_len = n;
    } else {
        @memcpy(base_url_buf[0..def.len], def);
        base_url_buf[def.len] = 0;
        base_url_len = def.len;
    }
    base_url_init = true;
    return base_url_buf[0..base_url_len];
}

fn ensureSlot() u8 {
    if (connector_slot != 255) return connector_slot;
    const url = ensureBaseUrl();
    var url_nt: [257]u8 = undefined;
    @memcpy(url_nt[0..url.len], url);
    url_nt[url.len] = 0;
    connector_slot = c.uapi_connector_create(VERISIMDB_SERVICE_ID,
        @as([*:0]const u8, @ptrCast(&url_nt)));
    if (connector_slot == 255) {
        std.debug.print("[aerie] verisimdb: connector pool exhausted\n", .{});
    }
    return connector_slot;
}

// ---------------------------------------------------------------------------
// httpPost — connector-backed POST helper
//
// Replaced: hand-rolled std.net.tcpConnectToAddress + HTTP/1.0 POST
// Replacement: uapi_connector_call (UAPI_METHOD_POST)
// ---------------------------------------------------------------------------

/// HTTP POST: send `body` to `path`, ignore the response (fire-and-forget).
fn httpPost(path: []const u8, body: []const u8) !void {
    const slot = ensureSlot();
    if (slot == 255) return error.ConnectorUnavailable;

    var path_nt: [512]u8 = undefined;
    const path_len = @min(path.len, 511);
    @memcpy(path_nt[0..path_len], path[0..path_len]);
    path_nt[path_len] = 0;

    var body_nt: [8192]u8 = undefined;
    const body_len = @min(body.len, 8191);
    @memcpy(body_nt[0..body_len], body[0..body_len]);
    body_nt[body_len] = 0;

    // Discard response (fire-and-forget).
    var discard: [256]u8 = undefined;

    const result_code = c.uapi_connector_call(
        slot,
        c.UAPI_METHOD_POST,
        @as([*:0]const u8, @ptrCast(&path_nt)),
        @as([*:0]const u8, @ptrCast(&body_nt)),
        &discard,
        @intCast(discard.len),
    );

    if (result_code != c.UAPI_OK) {
        return error.ConnectorCallFailed;
    }
}

// ---------------------------------------------------------------------------
// httpGet — connector-backed GET helper
//
// Replaced: delegation to librespeed_client.httpGet (hand-rolled TCP)
// Replacement: uapi_connector_call (UAPI_METHOD_GET) on verisimdb's own slot
// ---------------------------------------------------------------------------

fn httpGet(url: []const u8, body_buf: []u8) ![]const u8 {
    const slot = ensureSlot();
    if (slot == 255) return error.ConnectorUnavailable;

    // Build path from the full URL.
    const base = ensureBaseUrl();
    const path_raw: []const u8 = if (std.mem.startsWith(u8, url, base))
        url[base.len..]
    else blk: {
        // URL uses a different base; extract path portion.
        const without_scheme = if (std.mem.startsWith(u8, url, "http://"))
            url[7..]
        else
            return error.UnsupportedScheme;
        const slash = std.mem.indexOfScalar(u8, without_scheme, '/') orelse without_scheme.len;
        break :blk if (slash < without_scheme.len) without_scheme[slash..] else "/";
    };

    var path_nt: [512]u8 = undefined;
    const path_len = @min(path_raw.len, 511);
    @memcpy(path_nt[0..path_len], path_raw[0..path_len]);
    path_nt[path_len] = 0;

    const empty_body: [1]u8 = .{0};

    const result_code = c.uapi_connector_call(
        slot,
        c.UAPI_METHOD_GET,
        @as([*:0]const u8, @ptrCast(&path_nt)),
        @as([*:0]const u8, @ptrCast(&empty_body)),
        body_buf.ptr,
        @intCast(body_buf.len),
    );

    if (result_code != c.UAPI_OK) {
        return error.ConnectorCallFailed;
    }

    const written_len = std.mem.indexOfScalar(u8, body_buf, 0) orelse body_buf.len;
    return body_buf[0..written_len];
}

// ---------------------------------------------------------------------------
// Public helpers
// ---------------------------------------------------------------------------

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
        var cv: VerisimDBClient = std.mem.zeroes(VerisimDBClient);
        const url = ensureBaseUrl();
        const n = @min(url.len, 255);
        @memcpy(cv.base_url[0..n], url[0..n]);
        cv.base_url[n]     = 0;
        cv.base_url_len    = n;
        return cv;
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

        httpPost("/api/v1/events", event_json) catch |err| {
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
    const body = httpGet(url, &body_buf) catch |err| {
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
        // No "events" key — push the raw body as-is.
        const owned = arena.dupe(u8, trimmed) catch return;
        out_list.append(arena, owned) catch {};
        return;
    };

    // Find the opening bracket after "events".
    const after = trimmed[events_pos + events_needle.len ..];
    const bracket_pos = std.mem.indexOfScalar(u8, after, '[') orelse {
        const owned = arena.dupe(u8, trimmed) catch return;
        out_list.append(arena, owned) catch {};
        return;
    };

    // Extract each {...} object from the array.
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
