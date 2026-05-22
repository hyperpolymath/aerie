// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// librespeed_client.zig — HTTP Client for LibreSpeed Probe
//
// Queries the LibreSpeed backend at LIBRESPEED_URL (default http://librespeed:8080)
// to obtain zero-telemetry speed test results.  Parses the response into
// TelemetrySample records matching the Idris2 ABI and protobuf definitions.
//
// Transport layer: uapi_connector_* (developer-ecosystem/zig-api) — replaces
// the hand-rolled std.net.tcpConnectToAddress / HTTP/1.0 send-recv loop.
// A single connector slot is lazily allocated on first use and reused for
// subsequent requests.  The slot is released on process exit via the
// library-level uapi_teardown() called in main.zig.
//
// Replaces: librespeed_client.v

const std = @import("std");
const t   = @import("types.zig");
const prf = @import("proof.zig");

/// C ABI imports from libzig_api.
const c = @cImport({
    @cInclude("zig_api.h");
});

// ---------------------------------------------------------------------------
// Connector slot (lazily initialised, module-level)
// ---------------------------------------------------------------------------

/// UAPI_SERVICE_AMBIENT_OPS is the nearest service-id for librespeed (an
/// ambient/probe service).  The service-id tag only affects pool diagnostics;
/// the actual target URL is set via the base_url argument to
/// uapi_connector_create.
const LIBRESPEED_SERVICE_ID: u8 = c.UAPI_SERVICE_AMBIENT_OPS;

/// 255 means "not yet allocated".
var connector_slot: u8 = 255;

/// URL buffer for the base URL read from the environment.
var base_url_buf: [256]u8 = undefined;
var base_url_len: usize   = 0;
var base_url_init: bool   = false;

fn ensureBaseUrl() []const u8 {
    if (base_url_init) return base_url_buf[0..base_url_len];
    const def = "http://librespeed:8080";
    if (std.posix.getenv("LIBRESPEED_URL")) |url| {
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

/// Ensure the connector slot is allocated.
/// Returns the slot index, or 255 on failure.
fn ensureSlot() u8 {
    if (connector_slot != 255) return connector_slot;
    const url = ensureBaseUrl();
    // uapi_connector_create expects a null-terminated string.
    var url_nt: [257]u8 = undefined;
    @memcpy(url_nt[0..url.len], url);
    url_nt[url.len] = 0;
    connector_slot = c.uapi_connector_create(LIBRESPEED_SERVICE_ID, &url_nt);
    if (connector_slot == 255) {
        std.debug.print("[aerie] librespeed: connector pool exhausted\n", .{});
    }
    return connector_slot;
}

// ---------------------------------------------------------------------------
// httpGet — public shared helper used by other clients
//
// Replaced: hand-rolled std.net.tcpConnectToAddress + HTTP/1.0 write/read
// Replacement: uapi_connector_call (UAPI_METHOD_GET)
// ---------------------------------------------------------------------------

/// HTTP GET helper: fetches `url`, writes body into `body_buf`.
/// Returns a slice of `body_buf` on success, or an error.
///
/// The `url` parameter must be an absolute URL beginning with "http://"
/// and must start with the LIBRESPEED_URL base.  Calls go through the
/// pooled connector slot for reuse.
pub fn httpGet(url: []const u8, body_buf: []u8) ![]const u8 {
    const slot = ensureSlot();
    if (slot == 255) return error.ConnectorUnavailable;

    // Extract the path portion of the URL.
    const without_scheme2 = if (std.mem.startsWith(u8, url, "http://"))
        url[7..]
    else
        url;
    const slash2 = std.mem.indexOfScalar(u8, without_scheme2, '/') orelse without_scheme2.len;
    const path_raw = if (slash2 < without_scheme2.len)
        without_scheme2[slash2..]
    else
        "/";

    // Null-terminate the path for uapi_connector_call.
    var path_nt: [512]u8 = undefined;
    const path_len = @min(path_raw.len, 511);
    @memcpy(path_nt[0..path_len], path_raw[0..path_len]);
    path_nt[path_len] = 0;

    // Empty body for GET.
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
        std.debug.print("[aerie] librespeed: GET {s} failed (code {d})\n",
            .{ url, result_code });
        return error.ConnectorCallFailed;
    }

    // uapi_connector_call writes the response body starting at body_buf[0].
    // Determine how many bytes were written by scanning for the null or the
    // end of the buffer.
    const written_len = std.mem.indexOfScalar(u8, body_buf, 0) orelse body_buf.len;
    return body_buf[0..written_len];
}

fn unavailableSample(out: *t.TelemetrySample, ts: []const u8) void {
    out.* = std.mem.zeroes(t.TelemetrySample);
    const n = @min(ts.len, 31);
    @memcpy(out.timestamp[0..n], ts[0..n]);
    out.timestamp[n] = 0;
    out.latency_ms  = -1;
    out.jitter_ms   = -1;
    out.packet_loss = -1;
}

/// Fetch current telemetry from LibreSpeed.
/// Writes the sample into `out`. Falls back to -1 values on any error.
pub fn getTelemetry(out: *t.TelemetrySample) void {
    var ts_buf: [32]u8 = undefined;
    prf.formatRfc3339(&ts_buf);
    const ts = std.mem.sliceTo(&ts_buf, 0);

    const base = ensureBaseUrl();

    var full_url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&full_url_buf, "{s}/backend/getIP.php", .{base})
        catch { unavailableSample(out, ts); return; };

    var body_buf: [4096]u8 = undefined;
    _ = httpGet(url, &body_buf) catch {
        std.debug.print("[aerie] librespeed: probe unreachable at {s}\n", .{base});
        unavailableSample(out, ts);
        return;
    };

    // Response received — Phase 2 will extract actual values.
    // Phase 1: return zero-value sample indicating reachability.
    out.* = std.mem.zeroes(t.TelemetrySample);
    const n = @min(ts.len, 31);
    @memcpy(out.timestamp[0..n], ts[0..n]);
    out.timestamp[n] = 0;
    out.latency_ms  = 0;
    out.jitter_ms   = 0;
    out.packet_loss = 0;
}

/// Serialise a TelemetrySample to JSON in `buf`. Returns slice of bytes written.
pub fn telemetrySampleToJson(s: t.TelemetrySample, buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf,
        "{{\"timestamp\":\"{s}\",\"latencyMs\":{d:.6},\"jitterMs\":{d:.6},\"packetLoss\":{d:.6}}}",
        .{
            std.mem.sliceTo(&s.timestamp, 0),
            s.latency_ms,
            s.jitter_ms,
            s.packet_loss,
        },
    );
}

/// Serialise a single TelemetrySample as a {"samples":[...]} payload in `buf`.
pub fn telemetryPayloadToJson(s: t.TelemetrySample, buf: []u8) ![]const u8 {
    var sample_buf: [256]u8 = undefined;
    const sample_json = try telemetrySampleToJson(s, &sample_buf);
    return try std.fmt.bufPrint(buf, "{{\"samples\":[{s}]}}", .{sample_json});
}
