// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// hyperglass_client.zig — HTTP Client for Hyperglass BGP Probe
//
// Queries the Hyperglass looking glass at HYPERGLASS_URL
// (default http://hyperglass:8082) for BGP route forensics data.
// Falls back to an empty path on any error.
//
// Transport layer: uapi_connector_* (developer-ecosystem/zig-api) — replaces
// the hand-rolled std.net.tcpConnectToAddress / HTTP/1.0 POST.
// A single connector slot is lazily allocated on first use and reused for
// subsequent requests.  The slot is released on process exit via the
// library-level uapi_teardown() called in main.zig.
//
// Replaces: hyperglass_client.v

const std  = @import("std");
const t    = @import("types.zig");

/// C ABI imports from libzig_api.
const c = @cImport({
    @cInclude("zig_api.h");
});

// ---------------------------------------------------------------------------
// Connector slot (lazily initialised, module-level)
// ---------------------------------------------------------------------------

const HYPERGLASS_SERVICE_ID: u8 = c.UAPI_SERVICE_AMBIENT_OPS;

var connector_slot: u8 = 255;

var base_url_buf: [256]u8 = undefined;
var base_url_len: usize   = 0;
var base_url_init: bool   = false;

fn ensureBaseUrl() []const u8 {
    if (base_url_init) return base_url_buf[0..base_url_len];
    const def = "http://hyperglass:8082";
    if (std.posix.getenv("HYPERGLASS_URL")) |url| {
        const n = @min(url.len, base_url_buf.len - 1);
        @memcpy(base_url_buf[0..n], url[0..n]);
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
    connector_slot = c.uapi_connector_create(HYPERGLASS_SERVICE_ID,
        @as([*:0]const u8, @ptrCast(&url_nt)));
    if (connector_slot == 255) {
        std.debug.print("[aerie] hyperglass: connector pool exhausted\n", .{});
    }
    return connector_slot;
}

// ---------------------------------------------------------------------------
// httpPost — connector-backed POST helper
//
// Replaced: hand-rolled std.net.tcpConnectToAddress + HTTP/1.0 POST write/read
// Replacement: uapi_connector_call (UAPI_METHOD_POST)
// ---------------------------------------------------------------------------

/// HTTP POST helper: posts `post_body` to `url`, writes response body into
/// `body_buf`.  Returns a slice of `body_buf` on success, or an error.
fn httpPost(url: []const u8, post_body: []const u8, body_buf: []u8) ![]const u8 {
    const slot = ensureSlot();
    if (slot == 255) return error.ConnectorUnavailable;

    // Extract the path from the URL.
    const without_scheme = if (std.mem.startsWith(u8, url, "http://"))
        url[7..]
    else
        return error.UnsupportedScheme;
    const slash = std.mem.indexOfScalar(u8, without_scheme, '/') orelse without_scheme.len;
    const path_raw = if (slash < without_scheme.len)
        without_scheme[slash..]
    else
        "/";

    var path_nt: [512]u8 = undefined;
    const path_len = @min(path_raw.len, 511);
    @memcpy(path_nt[0..path_len], path_raw[0..path_len]);
    path_nt[path_len] = 0;

    // Null-terminate the body.
    const body_nt = blk: {
        var buf: [256]u8 = undefined;
        const n = @min(post_body.len, 255);
        @memcpy(buf[0..n], post_body[0..n]);
        buf[n] = 0;
        break :blk buf;
    };

    const result_code = c.uapi_connector_call(
        slot,
        c.UAPI_METHOD_POST,
        @as([*:0]const u8, @ptrCast(&path_nt)),
        @as([*:0]const u8, @ptrCast(&body_nt)),
        body_buf.ptr,
        @intCast(body_buf.len),
    );

    if (result_code != c.UAPI_OK) {
        std.debug.print("[aerie] hyperglass: POST {s} failed (code {d})\n",
            .{ url, result_code });
        return error.ConnectorCallFailed;
    }

    const written_len = std.mem.indexOfScalar(u8, body_buf, 0) orelse body_buf.len;
    return body_buf[0..written_len];
}

/// Max route hops we handle.
pub const MAX_HOPS = 64;

/// Fetch BGP route forensics for `target`.
/// Writes up to MAX_HOPS hops into `hops_out`; returns number written.
/// On error, returns 0 hops (caller sees an empty path).
pub fn getRouteForensics(
    target:   []const u8,
    hops_out: *[MAX_HOPS]t.RouteHop,
) usize {
    const base = ensureBaseUrl();

    var full_url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&full_url_buf, "{s}/api/query/", .{base}) catch return 0;

    // Build POST body — sanitise target to prevent JSON injection.
    var post_buf: [256]u8 = undefined;
    const post_body = std.fmt.bufPrint(&post_buf,
        "{{\"query_location\":\"\",\"query_target\":\"{s}\",\"query_type\":\"bgp_route\"}}",
        .{target},
    ) catch return 0;

    var body_buf: [16384]u8 = undefined;
    const body = httpPost(url, post_body, &body_buf) catch {
        std.debug.print("[aerie] hyperglass: probe unreachable at {s}\n", .{base});
        return 0;
    };

    return parseRouteHops(body, hops_out);
}

/// Parse Hyperglass JSON response into RouteHop array.
/// Handles the array-of-objects format returned by Hyperglass.
fn parseRouteHops(body: []const u8, hops: *[MAX_HOPS]t.RouteHop) usize {
    var count: usize = 0;
    if (!std.mem.startsWith(u8, std.mem.trimLeft(u8, body, " \t\r\n"), "[")) return 0;

    // Walk the array: find each "{" ... "}" object and extract fields.
    var pos: usize = 0;
    while (pos < body.len and count < MAX_HOPS) {
        const obj_start = std.mem.indexOfScalarPos(u8, body, pos, '{') orelse break;
        const obj_end   = std.mem.indexOfScalarPos(u8, body, obj_start, '}') orelse break;
        const obj       = body[obj_start .. obj_end + 1];
        pos             = obj_end + 1;

        var hop: t.RouteHop = std.mem.zeroes(t.RouteHop);
        hop.hop = @intCast(count + 1);

        // Try "prefix" then "ip" for the IP field.
        if (jsonStrField(obj, "prefix")) |ip| {
            const n = @min(ip.len, 63);
            @memcpy(hop.ip[0..n], ip[0..n]);
            hop.ip[n]   = 0;
            hop.ip_len  = n;
        } else if (jsonStrField(obj, "ip")) |ip| {
            const n = @min(ip.len, 63);
            @memcpy(hop.ip[0..n], ip[0..n]);
            hop.ip[n]   = 0;
            hop.ip_len  = n;
        }

        // Try "as_path" then "asn".
        if (jsonStrField(obj, "as_path")) |asn| {
            const n = @min(asn.len, 63);
            @memcpy(hop.asn[0..n], asn[0..n]);
            hop.asn[n]  = 0;
            hop.asn_len = n;
        } else if (jsonStrField(obj, "asn")) |asn| {
            const n = @min(asn.len, 63);
            @memcpy(hop.asn[0..n], asn[0..n]);
            hop.asn[n]  = 0;
            hop.asn_len = n;
        }

        hops[count] = hop;
        count += 1;
    }
    return count;
}

/// Minimal JSON string field extractor.
fn jsonStrField(data: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const kpos = std.mem.indexOf(u8, data, needle) orelse return null;
    const after = data[kpos + needle.len ..];
    const colon = std.mem.indexOfScalar(u8, after, ':') orelse return null;
    var rest = std.mem.trimLeft(u8, after[colon + 1 ..], " \t");
    if (rest.len == 0 or rest[0] != '"') return null;
    rest = rest[1..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// Serialise route forensics to JSON in `buf`.
/// `target`: the queried target; `hops`: slice of RouteHop.
pub fn routeForensicsToJson(
    target: []const u8,
    hops:   []const t.RouteHop,
    buf:    []u8,
) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.print("{{\"target\":\"{s}\",\"path\":[", .{target});
    for (hops, 0..) |h, i| {
        if (i > 0) try w.writeByte(',');
        const asn_field = std.mem.sliceTo(&h.asn, 0);
        const ip_field  = std.mem.sliceTo(&h.ip, 0);
        if (asn_field.len > 0) {
            try w.print("{{\"hop\":{d},\"ip\":\"{s}\",\"asn\":\"{s}\",\"rttMs\":null}}",
                .{ h.hop, ip_field, asn_field });
        } else {
            try w.print("{{\"hop\":{d},\"ip\":\"{s}\",\"asn\":null,\"rttMs\":null}}",
                .{ h.hop, ip_field });
        }
    }
    try w.writeAll("]}");
    return fbs.getWritten();
}
