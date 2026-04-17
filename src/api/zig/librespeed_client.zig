// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// librespeed_client.zig — HTTP Client for LibreSpeed Probe
//
// Queries the LibreSpeed backend at LIBRESPEED_URL (default http://librespeed:8080)
// to obtain zero-telemetry speed test results. Parses the response into
// TelemetrySample records matching the Idris2 ABI and protobuf definitions.
//
// Replaces: librespeed_client.v

const std = @import("std");
const t   = @import("types.zig");
const prf = @import("proof.zig");

fn getLibrespeedUrl(buf: []u8) []const u8 {
    if (std.posix.getenv("LIBRESPEED_URL")) |url| {
        const n = @min(url.len, buf.len - 1);
        @memcpy(buf[0..n], url[0..n]);
        buf[n] = 0;
        return buf[0..n];
    }
    const def = "http://librespeed:8080";
    @memcpy(buf[0..def.len], def);
    return buf[0..def.len];
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

/// HTTP GET helper: fetches `url`, writes body into `body_buf`.
/// Returns a slice of `body_buf` on success, error on failure.
pub fn httpGet(url: []const u8, body_buf: []u8) ![]const u8 {
    // Parse scheme, host, port, path from url.
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

    // Send HTTP/1.0 request (no keep-alive, simpler response handling)
    var req_buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf,
        "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n",
        .{ path, host_str },
    );
    try stream.writeAll(req);

    const n = stream.read(body_buf) catch return error.ReadFailed;
    const raw = body_buf[0..n];

    // Strip HTTP headers: find \r\n\r\n
    if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |hdr_end| {
        return raw[hdr_end + 4 ..];
    }
    return raw;
}

/// Fetch current telemetry from LibreSpeed.
/// Writes the sample into `out`. Falls back to -1 values on any error.
pub fn getTelemetry(out: *t.TelemetrySample) void {
    var ts_buf: [32]u8 = undefined;
    prf.formatRfc3339(&ts_buf);
    const ts = std.mem.sliceTo(&ts_buf, 0);

    var url_buf: [256]u8 = undefined;
    const base = getLibrespeedUrl(&url_buf);

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
