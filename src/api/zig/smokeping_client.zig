// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// smokeping_client.zig — HTTP Client for SmokePing Probe
//
// Queries the SmokePing backend at SMOKEPING_URL (default http://smokeping:80)
// to obtain latency, packet loss, and jitter metrics.
// Falls back to -1 values when the probe is unreachable.
//
// Replaces: smokeping_client.v

const std  = @import("std");
const t    = @import("types.zig");
const prf  = @import("proof.zig");
const ls   = @import("librespeed_client.zig");

fn getSmokepingUrl(buf: []u8) []const u8 {
    if (std.posix.getenv("SMOKEPING_URL")) |url| {
        const n = @min(url.len, buf.len - 1);
        @memcpy(buf[0..n], url[0..n]);
        buf[n] = 0;
        return buf[0..n];
    }
    const def = "http://smokeping:80";
    @memcpy(buf[0..def.len], def);
    return buf[0..def.len];
}

pub const MAX_CHART_POINTS = 288;

/// Fetch SmokePing latency/loss data for `target`.
/// Writes current sample into `current_out` and up to MAX_CHART_POINTS
/// historical points into `chart_out`; returns number of chart points written.
pub fn getSmokepingData(
    target:      []const u8,
    current_out: *t.SmokePingSample,
    chart_out:   *[MAX_CHART_POINTS]t.SmokeChartPoint,
) usize {
    var ts_buf: [32]u8 = undefined;
    prf.formatRfc3339(&ts_buf);
    const ts = std.mem.sliceTo(&ts_buf, 0);

    // Initialise current_out to unavailable defaults.
    current_out.* = std.mem.zeroes(t.SmokePingSample);
    const ts_n    = @min(ts.len, 31);
    @memcpy(current_out.timestamp[0..ts_n], ts[0..ts_n]);
    current_out.timestamp[ts_n] = 0;
    const tgt_n   = @min(target.len, 127);
    @memcpy(current_out.target[0..tgt_n], target[0..tgt_n]);
    current_out.target[tgt_n] = 0;
    current_out.target_len = tgt_n;

    var url_buf: [256]u8 = undefined;
    const base = getSmokepingUrl(&url_buf);

    var cgi_buf: [512]u8 = undefined;
    const cgi_url = std.fmt.bufPrint(&cgi_buf,
        "{s}/smokeping/smokeping.cgi?target={s}&displaymode=s",
        .{ base, target },
    ) catch {
        setUnavailable(current_out, ts, target);
        return 0;
    };

    var body_buf: [32768]u8 = undefined;
    const body = ls.httpGet(cgi_url, &body_buf) catch {
        std.debug.print("[aerie] smokeping: probe unreachable at {s}\n", .{base});
        setUnavailable(current_out, ts, target);
        return 0;
    };

    const chart_count = parseSmokepingResponse(body, target, chart_out);

    if (chart_count > 0) {
        const last = chart_out[chart_count - 1];
        current_out.median_ms = last.median_ms;
        current_out.loss_pct  = last.loss_pct;
        current_out.min_ms    = last.median_ms; // approximation (CGI summary lacks min/max)
        current_out.max_ms    = last.median_ms;
        current_out.stddev_ms = 0;
        // Timestamp from last chart point
        const pts_ts = std.mem.sliceTo(&last.timestamp, 0);
        const pts_n  = @min(pts_ts.len, 31);
        @memcpy(current_out.timestamp[0..pts_n], pts_ts[0..pts_n]);
        current_out.timestamp[pts_n] = 0;
    }
    // else leave zeroes from init

    return chart_count;
}

fn setUnavailable(out: *t.SmokePingSample, ts: []const u8, target: []const u8) void {
    out.median_ms = -1;
    out.loss_pct  = -1;
    out.min_ms    = -1;
    out.max_ms    = -1;
    out.stddev_ms = -1;
    _ = ts;
    _ = target;
}

/// Parse SmokePing CGI HTML response for embedded numerical data.
/// Mirrors parse_smokeping_response() from smokeping_client.v.
fn parseSmokepingResponse(
    body:   []const u8,
    target: []const u8,
    out:    *[MAX_CHART_POINTS]t.SmokeChartPoint,
) usize {
    _ = target;
    var count: usize = 0;

    var line_iter = std.mem.splitScalar(u8, body, '\n');
    while (line_iter.next()) |raw_line| {
        if (count >= MAX_CHART_POINTS) break;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        // Strategy 1: CSV-style numeric lines starting with a digit
        if (std.ascii.isDigit(line[0])) {
            var fields = std.mem.splitScalar(u8, line, ',');
            const ts_str = fields.next() orelse continue;
            const med_str = fields.next() orelse continue;
            const loss_str = fields.next() orelse continue;

            const median = std.fmt.parseFloat(f64, std.mem.trim(u8, med_str, " \t")) catch continue;
            const loss   = std.fmt.parseFloat(f64, std.mem.trim(u8, loss_str, " \t")) catch 0;
            if (median < 0) continue;

            var pt: t.SmokeChartPoint = std.mem.zeroes(t.SmokeChartPoint);
            const ts_trimmed = std.mem.trim(u8, ts_str, " \t");
            const ts_n = @min(ts_trimmed.len, 31);
            @memcpy(pt.timestamp[0..ts_n], ts_trimmed[0..ts_n]);
            pt.timestamp[ts_n] = 0;
            pt.median_ms = median;
            pt.loss_pct  = loss;
            out[count]   = pt;
            count += 1;
            continue;
        }

        // Strategy 2: RRD XML <row><v>...</v>...</row>
        if (std.mem.startsWith(u8, line, "<row>") and std.mem.indexOf(u8, line, "<v>") != null) {
            var values: [4][]const u8 = .{ "", "", "", "" };
            var vcount: usize = 0;
            var rest = line;
            while (vcount < 4) {
                const vs = std.mem.indexOf(u8, rest, "<v>") orelse break;
                const ve = std.mem.indexOf(u8, rest, "</v>") orelse break;
                if (ve < vs + 3) break;
                values[vcount] = rest[vs + 3 .. ve];
                rest = rest[ve + 4 ..];
                vcount += 1;
            }
            if (vcount < 3) continue;

            const median = std.fmt.parseFloat(f64, values[1]) catch continue;
            const loss   = std.fmt.parseFloat(f64, values[2]) catch 0;

            var pt: t.SmokeChartPoint = std.mem.zeroes(t.SmokeChartPoint);
            const ts_n = @min(values[0].len, 31);
            @memcpy(pt.timestamp[0..ts_n], values[0][0..ts_n]);
            pt.timestamp[ts_n] = 0;
            pt.median_ms = median;
            pt.loss_pct  = loss;
            out[count]   = pt;
            count += 1;
        }
    }
    return count;
}

/// Serialise SmokePing payload to JSON in `buf`.
pub fn smokepingPayloadToJson(
    current:     t.SmokePingSample,
    chart:       []const t.SmokeChartPoint,
    buf:         []u8,
) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    const c = current;
    try w.print(
        "{{\"target\":\"{s}\",\"current\":{{\"timestamp\":\"{s}\",\"target\":\"{s}\"," ++
        "\"medianMs\":{d:.6},\"lossPct\":{d:.6},\"minMs\":{d:.6},\"maxMs\":{d:.6},\"stddevMs\":{d:.6}}}," ++
        "\"chart\":[",
        .{
            std.mem.sliceTo(&c.target,    0),
            std.mem.sliceTo(&c.timestamp, 0),
            std.mem.sliceTo(&c.target,    0),
            c.median_ms, c.loss_pct, c.min_ms, c.max_ms, c.stddev_ms,
        },
    );
    for (chart, 0..) |pt, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"timestamp\":\"{s}\",\"medianMs\":{d:.6},\"lossPct\":{d:.6}}}",
            .{ std.mem.sliceTo(&pt.timestamp, 0), pt.median_ms, pt.loss_pct });
    }
    try w.writeAll("]}");
    return fbs.getWritten();
}
