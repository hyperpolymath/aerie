// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// redis_client.zig — Redis Client for Cache and Audit Log
//
// Provides two capabilities:
//   1. Result caching with TTL — avoids hammering backend probes
//   2. Audit log — append-only list of AuditEvent records
//
// Uses raw RESP3 protocol over TCP; zero external dependencies.
// Redis at REDIS_URL environment variable (default redis://redis:6379).
//
// Connection is lazily established on first command, with a single
// reconnect retry on write failure.
//
// Replaces: redis_client.v

const std = @import("std");
const t   = @import("types.zig");
const vc  = @import("verisim_client.zig");

const MAX_RESPONSE  = 8192;
const AUDIT_CAP_STR = "-10000";

pub const RedisError = error{
    ConnectFailed,
    WriteFailed,
    ReadFailed,
    NotConnected,
};

/// RedisClient holds connection state.
/// Call init() to build it; call deinit() when done.
pub const RedisClient = struct {
    host:       [128]u8,
    host_len:   usize,
    port:       u16,
    stream:     ?std.net.Stream,
    allocator:  std.mem.Allocator,

    /// Build a RedisClient from REDIS_URL (or default redis://redis:6379).
    pub fn init(allocator: std.mem.Allocator) RedisClient {
        var host_buf: [128]u8 = std.mem.zeroes([128]u8);
        var port: u16 = 6379;
        var host_len: usize = 5;
        @memcpy(host_buf[0..5], "redis");

        if (std.posix.getenv("REDIS_URL")) |url| {
            // Parse redis://host:port
            const stripped = if (std.mem.startsWith(u8, url, "redis://"))
                url["redis://".len..]
            else url;
            if (std.mem.indexOfScalar(u8, stripped, ':')) |ci| {
                const h = stripped[0..ci];
                const n = @min(h.len, 127);
                @memcpy(host_buf[0..n], h[0..n]);
                host_buf[n] = 0;
                host_len = n;
                const p = std.fmt.parseInt(u16, stripped[ci + 1 ..], 10) catch 6379;
                if (p != 0) port = p;
            } else {
                const n = @min(stripped.len, 127);
                @memcpy(host_buf[0..n], stripped[0..n]);
                host_buf[n] = 0;
                host_len = n;
            }
        }

        return .{
            .host      = host_buf,
            .host_len  = host_len,
            .port      = port,
            .stream    = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RedisClient) void {
        if (self.stream) |s| s.close();
        self.stream = null;
    }

    /// Establish TCP connection to Redis if not already connected.
    fn ensureConnected(self: *RedisClient) RedisError!void {
        if (self.stream != null) return;
        const host_str = self.host[0..self.host_len];
        const addr = std.net.Address.resolveIp(host_str, self.port) catch
            std.net.Address.parseIp4(host_str, self.port) catch {
                std.debug.print("[aerie] redis: cannot resolve {s}:{d}\n",
                    .{ host_str, self.port });
                return RedisError.ConnectFailed;
            };
        self.stream = std.net.tcpConnectToAddress(addr) catch {
            std.debug.print("[aerie] redis: connect failed to {s}:{d}\n",
                .{ host_str, self.port });
            return RedisError.ConnectFailed;
        };
    }

    /// Send a RESP array command and return the raw response in `resp_buf`.
    /// Returns a slice of `resp_buf` containing the server's response.
    fn sendCommand(
        self:     *RedisClient,
        args:     []const []const u8,
        resp_buf: []u8,
    ) RedisError![]const u8 {
        try self.ensureConnected();

        // Build RESP array into a stack buffer (max ~4096 for typical commands)
        var cmd_buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&cmd_buf);
        const w = fbs.writer();
        w.print("*{d}\r\n", .{args.len}) catch return RedisError.WriteFailed;
        for (args) |arg| {
            w.print("${d}\r\n{s}\r\n", .{ arg.len, arg }) catch return RedisError.WriteFailed;
        }
        const cmd = fbs.getWritten();

        // Write, retrying once on broken-pipe
        const stream = self.stream orelse return RedisError.NotConnected;
        stream.writeAll(cmd) catch {
            // Connection dropped; reconnect once
            stream.close();
            self.stream = null;
            try self.ensureConnected();
            const s2 = self.stream orelse return RedisError.NotConnected;
            s2.writeAll(cmd) catch return RedisError.WriteFailed;
        };

        const s3 = self.stream orelse return RedisError.NotConnected;
        const n = s3.read(resp_buf) catch return RedisError.ReadFailed;
        return resp_buf[0..n];
    }

    /// Cache a result at key "aerie:cache:<key>" with TTL seconds.
    pub fn cacheResult(self: *RedisClient, key: []const u8, value: []const u8, ttl: u32) void {
        var k_buf: [128]u8 = undefined;
        const prefixed_key = std.fmt.bufPrint(&k_buf, "aerie:cache:{s}", .{key})
            catch { std.debug.print("[aerie] redis: key too long\n", .{}); return; };

        var ttl_buf: [12]u8 = undefined;
        const ttl_str = std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl}) catch return;

        var resp_buf: [MAX_RESPONSE]u8 = undefined;
        _ = self.sendCommand(&.{ "SET", prefixed_key, value, "EX", ttl_str }, &resp_buf)
            catch |err| {
                std.debug.print("[aerie] redis: cacheResult failed: {s}\n",
                    .{@errorName(err)});
            };
    }

    /// Retrieve a cached value. Returns empty slice if absent or Redis unreachable.
    /// The returned slice points into `out_buf` (caller provides storage).
    pub fn getCached(
        self:    *RedisClient,
        key:     []const u8,
        out_buf: []u8,
    ) []const u8 {
        var k_buf: [128]u8 = undefined;
        const prefixed_key = std.fmt.bufPrint(&k_buf, "aerie:cache:{s}", .{key})
            catch return "";

        var resp_buf: [MAX_RESPONSE]u8 = undefined;
        const resp = self.sendCommand(&.{ "GET", prefixed_key }, &resp_buf) catch return "";

        // RESP bulk string: $<len>\r\n<data>\r\n  or  $-1\r\n  (nil)
        if (std.mem.startsWith(u8, resp, "$-1")) return "";
        if (resp.len < 4 or resp[0] != '$') return "";

        const crlf1 = std.mem.indexOfScalar(u8, resp, '\n') orelse return "";
        const data_start = crlf1 + 1;
        if (data_start >= resp.len) return "";

        const crlf2 = std.mem.indexOf(u8, resp[data_start..], "\r\n") orelse
            (resp.len - data_start);
        const data = resp[data_start..][0..crlf2];
        const n = @min(data.len, out_buf.len);
        @memcpy(out_buf[0..n], data[0..n]);
        return out_buf[0..n];
    }

    /// Append an AuditEvent to the Redis list "aerie:audit".
    /// Caps the list at 10000 entries via LTRIM.
    pub fn logAudit(self: *RedisClient, ev: t.AuditEvent) void {
        var json_buf: [512]u8 = undefined;
        const event_json = vc.auditEventToJson(ev, &json_buf) catch {
            std.debug.print("[aerie] redis: logAudit serialise failed\n", .{});
            return;
        };

        var resp_buf: [MAX_RESPONSE]u8 = undefined;
        _ = self.sendCommand(&.{ "RPUSH", "aerie:audit", event_json }, &resp_buf)
            catch |err| {
                std.debug.print("[aerie] redis: logAudit RPUSH failed: {s}\n",
                    .{@errorName(err)});
                return;
            };
        _ = self.sendCommand(&.{ "LTRIM", "aerie:audit", AUDIT_CAP_STR, "-1" }, &resp_buf)
            catch |err| {
                std.debug.print("[aerie] redis: logAudit LTRIM failed: {s}\n",
                    .{@errorName(err)});
            };
    }

    /// Retrieve the most recent `limit` audit events from Redis.
    /// Appends each JSON string to `out_list`; caller owns the ArrayList.
    pub fn getAuditLog(
        self:     *RedisClient,
        limit:    u32,
        out_list: *std.ArrayList([]const u8),
        arena:    std.mem.Allocator,
    ) void {
        const cap: u32 = if (limit == 0) 50 else limit;
        var range_buf: [16]u8 = undefined;
        const range_str = std.fmt.bufPrint(&range_buf, "-{d}", .{cap}) catch return;

        var resp_buf: [MAX_RESPONSE]u8 = undefined;
        const resp = self.sendCommand(
            &.{ "LRANGE", "aerie:audit", range_str, "-1" },
            &resp_buf,
        ) catch return;

        // Parse RESP array: *<N>\r\n  then pairs of $<len>\r\n<data>\r\n
        parseRespArray(resp, out_list, arena);
    }
};

/// Parse a RESP array response and push each string element onto `list`.
/// Elements are duped into `arena` so the response buffer may be freed.
fn parseRespArray(
    resp:  []const u8,
    list:  *std.ArrayList([]const u8),
    arena: std.mem.Allocator,
) void {
    if (resp.len == 0 or resp[0] != '*') return;
    var pos: usize = 0;

    // Skip past the count line
    while (pos < resp.len and resp[pos] != '\n') pos += 1;
    if (pos >= resp.len) return;
    pos += 1;  // skip '\n'

    while (pos < resp.len) {
        if (resp[pos] != '$') {
            // Skip unexpected line
            while (pos < resp.len and resp[pos] != '\n') pos += 1;
            if (pos < resp.len) pos += 1;
            continue;
        }
        // Read length
        pos += 1;
        const len_start = pos;
        while (pos < resp.len and resp[pos] != '\r') pos += 1;
        const len_str = resp[len_start..pos];
        const data_len = std.fmt.parseInt(usize, len_str, 10) catch {
            while (pos < resp.len and resp[pos] != '\n') pos += 1;
            if (pos < resp.len) pos += 1;
            continue;
        };
        // Skip \r\n after length
        if (pos + 1 < resp.len) pos += 2;

        // Read data
        if (pos + data_len > resp.len) break;
        const data = resp[pos..][0..data_len];
        pos += data_len;
        // Skip trailing \r\n
        if (pos + 1 < resp.len and resp[pos] == '\r') pos += 2;

        const owned = arena.dupe(u8, data) catch break;
        list.append(arena, owned) catch break;
    }
}
