// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// main.zig — Aerie Gateway: Triple-Mount API Server (Zig port)
//
// Serves up to three API protocols from a single gateway process:
//
//   1. GraphQL  — POST /graphql                              (port 4000)
//   2. REST     — GET  /api/v1/{telemetry,routes,audit,...}  (port 4000)
//   3. gRPC     — length-prefixed JSON over TCP              (port 4001)
//
// Environment variables:
//   PORT          — HTTP port (default 4000)
//   GRPC_PORT     — gRPC port (default 4001)
//   ENABLE_REST   — "false"/"0"/"no" to disable (default enabled)
//   ENABLE_GRAPHQL— same
//   ENABLE_GRPC   — same
//
// Protocol enablement is read once at startup; disabled protocols bind
// no socket — zero attack surface.
//
// All responses are wrapped in a ProofEnvelope (SHA-256 hash, Phase 1).
// The policy gate checks X-Api-Key headers and logs all access to Redis.
//
// Replaces: main.v (src/api/v/main.v)
// Requires: Zig 0.15.2+

const std  = @import("std");
const t    = @import("types.zig");
const prf  = @import("proof.zig");
const pol  = @import("policy.zig");
const vg   = @import("verb_governance.zig");
const rc   = @import("redis_client.zig");
const vc   = @import("verisim_client.zig");
const res  = @import("resolvers.zig");

// ---------------------------------------------------------------------------
// Configuration helpers
// ---------------------------------------------------------------------------

/// Read a boolean env var. "false", "0", or "no" (case-insensitive) → false.
/// Anything else (including absent) → `default`.
fn envBool(name: []const u8, default: bool) bool {
    const val = std.posix.getenv(name) orelse return default;
    if (val.len == 0) return default;
    return !(std.ascii.eqlIgnoreCase(val, "false") or
             std.ascii.eqlIgnoreCase(val, "0")     or
             std.ascii.eqlIgnoreCase(val, "no"));
}

fn readProtocolConfig() t.ProtocolConfig {
    return .{
        .rest_enabled    = envBool("ENABLE_REST",    true),
        .graphql_enabled = envBool("ENABLE_GRAPHQL", true),
        .grpc_enabled    = envBool("ENABLE_GRPC",    true),
    };
}

/// Print the startup banner to stdout.
fn printBanner(http_port: u16, grpc_port: u16, cfg: t.ProtocolConfig) void {
    std.debug.print(
        "╔══════════════════════════════════════════════════════════╗\n" ++
        "║          AERIE GATEWAY — Zig port (PMPL-1.0-or-later)   ║\n" ++
        "╠══════════════════════════════════════════════════════════╣\n",
        .{},
    );
    if (cfg.rest_enabled) {
        std.debug.print("║  REST            : port {d:<5} ✓ ENABLED                 ║\n", .{http_port});
    } else {
        std.debug.print("║  REST            : ✗ DISABLED (no socket bound)         ║\n", .{});
    }
    if (cfg.graphql_enabled) {
        std.debug.print("║  GraphQL         : port {d:<5} ✓ ENABLED                 ║\n", .{http_port});
    } else {
        std.debug.print("║  GraphQL         : ✗ DISABLED (no socket bound)         ║\n", .{});
    }
    if (cfg.grpc_enabled) {
        std.debug.print("║  gRPC            : port {d:<5} ✓ ENABLED                 ║\n", .{grpc_port});
    } else {
        std.debug.print("║  gRPC            : ✗ DISABLED (no socket bound)         ║\n", .{});
    }
    std.debug.print(
        "╠══════════════════════════════════════════════════════════╣\n" ++
        "║  Proof mode      : light (SHA-256)                      ║\n" ++
        "║  Policy gate     : Phase 1 (permissive)                 ║\n" ++
        "╚══════════════════════════════════════════════════════════╝\n",
        .{},
    );
}

// ---------------------------------------------------------------------------
// HTTP helpers (mirroring the LOL reference gateway pattern)
// ---------------------------------------------------------------------------

fn readLine(stream: std.net.Stream, buf: []u8) ![]const u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = try stream.read(buf[pos..][0..1]);
        if (n == 0) break;
        if (buf[pos] == '\n') {
            const end = if (pos > 0 and buf[pos - 1] == '\r') pos - 1 else pos;
            return buf[0..end];
        }
        pos += 1;
    }
    return buf[0..pos];
}

/// Write a full HTTP/1.1 response with aerie security headers.
fn writeHttpResponse(
    stream:       std.net.Stream,
    status:       u16,
    status_text:  []const u8,
    content_type: []const u8,
    body:         []const u8,
) void {
    var hdr_buf: [1024]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf,
        "HTTP/1.1 {d} {s}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Access-Control-Allow-Headers: Content-Type, X-Api-Key\r\n" ++
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
        "X-Aerie-Proof-Type: light\r\n" ++
        "X-Content-Type-Options: nosniff\r\n" ++
        "X-Frame-Options: DENY\r\n" ++
        "X-XSS-Protection: 0\r\n" ++
        "Referrer-Policy: no-referrer\r\n" ++
        "Cache-Control: no-store\r\n" ++
        "\r\n",
        .{ status, status_text, content_type, body.len },
    ) catch return;
    stream.writeAll(hdr)  catch return;
    stream.writeAll(body) catch return;
}

fn writeJson(stream: std.net.Stream, status: u16, body: []const u8) void {
    const text: []const u8 = switch (status) {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        else => "Internal Server Error",
    };
    writeHttpResponse(stream, status, text, "application/json", body);
}

// ---------------------------------------------------------------------------
// HTTP request parsing and routing
// ---------------------------------------------------------------------------

const HttpRequest = struct {
    method:         []const u8,
    path:           []const u8,
    raw_path:       []const u8,
    api_key:        []const u8,
    content_length: usize,
};

/// Parse the first line and headers from an HTTP request.
/// Uses arena allocator for slices. `line_buf` is scratch space.
fn parseRequest(
    stream:   std.net.Stream,
    line_buf: []u8,
    arena:    std.mem.Allocator,
) !HttpRequest {
    const req_line = try readLine(stream, line_buf);
    var parts = std.mem.splitScalar(u8, req_line, ' ');
    const method   = parts.next() orelse return error.BadRequest;
    const raw_path = parts.next() orelse return error.BadRequest;

    const path = if (std.mem.indexOfScalar(u8, raw_path, '?')) |qi|
        raw_path[0..qi] else raw_path;

    var api_key: []const u8 = "";
    var content_length: usize = 0;

    var h_buf: [1024]u8 = undefined;
    while (true) {
        const line = readLine(stream, &h_buf) catch break;
        if (line.len == 0) break;  // blank line = end of headers
        if (std.ascii.startsWithIgnoreCase(line, "x-api-key:")) {
            const v = std.mem.trim(u8, line["x-api-key:".len..], " \t");
            api_key = try arena.dupe(u8, v);
        } else if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const v = std.mem.trim(u8, line["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, v, 10) catch 0;
        }
    }

    return .{
        .method         = try arena.dupe(u8, method),
        .path           = try arena.dupe(u8, path),
        .raw_path       = try arena.dupe(u8, raw_path),
        .api_key        = api_key,
        .content_length = content_length,
    };
}

/// Extract a query parameter from a raw URL string.
/// Returns a slice into `url`, or empty if absent.
fn queryParam(url: []const u8, name: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return "";
    const query_str = url[q + 1 ..];
    var pairs = std.mem.splitScalar(u8, query_str, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return "";
}

/// Module name from path, used for the policy gate log.
fn moduleFromPath(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "/graphql"))              return "graphql";
    if (std.mem.startsWith(u8, path, "/api/v1/telemetry"))     return "telemetry";
    if (std.mem.startsWith(u8, path, "/api/v1/routes"))        return "routes";
    if (std.mem.startsWith(u8, path, "/api/v1/audit/temporal"))return "temporal_audit";
    if (std.mem.startsWith(u8, path, "/api/v1/audit"))         return "audit";
    if (std.mem.startsWith(u8, path, "/api/v1/smokeping"))     return "smokeping";
    if (std.mem.startsWith(u8, path, "/api/v1/health"))        return "health";
    return "unknown";
}

/// Health check JSON, always available.
fn healthJson(cfg: t.ProtocolConfig, out: []u8) []const u8 {
    var ts_buf: [32]u8 = undefined;
    prf.formatRfc3339(&ts_buf);
    const ts = std.mem.sliceTo(&ts_buf, 0);
    var active: u8 = 0;
    if (cfg.rest_enabled)    active += 1;
    if (cfg.graphql_enabled) active += 1;
    if (cfg.grpc_enabled)    active += 1;
    var bound: u8 = 0;
    if (cfg.rest_enabled or cfg.graphql_enabled) bound += 1;
    if (cfg.grpc_enabled) bound += 1;
    return std.fmt.bufPrint(out,
        "{{\"status\":\"healthy\",\"service\":\"aerie-gateway\",\"version\":\"0.3.0\"," ++
        "\"timestamp\":\"{s}\",\"protocols\":{{\"rest\":{s},\"graphql\":{s},\"grpc\":{s}}}," ++
        "\"active_protocols\":{d},\"bound_ports\":{d}," ++
        "\"verb_governance\":true,\"stealth_mode\":true,\"proof_mode\":\"light\",\"policy_phase\":1}}",
        .{
            ts,
            if (cfg.rest_enabled)    "true" else "false",
            if (cfg.graphql_enabled) "true" else "false",
            if (cfg.grpc_enabled)    "true" else "false",
            active, bound,
        },
    ) catch "{\"status\":\"healthy\"}";
}

/// Not-found JSON, listing only enabled endpoints.
fn notFoundJson(cfg: t.ProtocolConfig, out: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();
    w.writeAll("{\"error\":\"Not found\",\"available_endpoints\":[") catch return "{\"error\":\"Not found\"}";
    var first = true;
    if (cfg.graphql_enabled) {
        w.writeAll("\"/graphql\"") catch {}; first = false;
    }
    if (cfg.rest_enabled) {
        if (!first) w.writeByte(',') catch {};
        w.writeAll("\"/api/v1/telemetry\",\"/api/v1/routes\",\"/api/v1/audit\"," ++
                   "\"/api/v1/audit/temporal\",\"/api/v1/smokeping\"") catch {};
    }
    w.writeAll(",\"/api/v1/health\"]}") catch {};
    return fbs.getWritten();
}

// ---------------------------------------------------------------------------
// Per-connection HTTP handler
// ---------------------------------------------------------------------------

const ConnArgs = struct {
    conn:      std.net.Server.Connection,
    cfg:       t.ProtocolConfig,
    redis:     *rc.RedisClient,
    verisimdb: vc.VerisimDBClient,
    alloc:     std.mem.Allocator,
};

fn handleHttpConn(args: ConnArgs) void {
    var conn = args.conn;
    defer conn.stream.close();

    var arena_inst = std.heap.ArenaAllocator.init(args.alloc);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var line_buf: [2048]u8 = undefined;
    const req = parseRequest(conn.stream, &line_buf, arena) catch return;

    // Verb governance — before policy gate
    const verb_dec = vg.check(req.method, req.raw_path);
    if (!verb_dec.allowed) {
        // Build audit event for denied verb
        var ts_buf: [32]u8 = undefined;
        prf.formatRfc3339(&ts_buf);
        var ev: t.AuditEvent = std.mem.zeroes(t.AuditEvent);
        prf.generateUuidV4(&ev.event_id);
        _ = @memcpy(ev.valid_time[0..20], ts_buf[0..20]); ev.valid_time[20] = 0;
        _ = @memcpy(ev.tx_time[0..20],    ts_buf[0..20]); ev.tx_time[20]    = 0;
        @memcpy(ev.severity[0..7], "warning"); ev.severity[7] = 0;
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf,
            "Verb denied: {s} on {s}",
            .{ std.mem.sliceTo(&verb_dec.verb, 0), req.raw_path },
        ) catch "Verb denied";
        ev.message_len = @min(msg.len, 255);
        @memcpy(ev.message[0..ev.message_len], msg[0..ev.message_len]);
        ev.message[ev.message_len] = 0;
        @memcpy(ev.tags[0][0..15], "verb-governance"); ev.tags[0][15] = 0;
        @memcpy(ev.tags[1][0..6],  "denied");          ev.tags[1][6]  = 0;
        ev.tag_count = 2;
        args.redis.logAudit(ev);

        if (verb_dec.stealth) vg.stealthDelay();

        var body_buf: [1024]u8 = undefined;
        const body = notFoundJson(args.cfg, &body_buf);
        const status: u16 = if (verb_dec.stealth) 404 else 405;
        writeJson(conn.stream, status, body);
        return;
    }

    // CORS preflight
    if (std.ascii.eqlIgnoreCase(req.method, "OPTIONS")) {
        writeHttpResponse(conn.stream, 204, "No Content", "text/plain", "");
        return;
    }

    // Policy gate
    const policy = pol.evaluatePolicy(req.api_key, moduleFromPath(req.path));
    if (!policy.allowed) {
        var reason_buf: [256]u8 = undefined;
        const reason = std.mem.sliceTo(&policy.reason, 0);
        const body = std.fmt.bufPrint(&reason_buf,
            "{{\"error\":\"Access denied\",\"reason\":\"{s}\"}}",
            .{reason},
        ) catch "{\"error\":\"Access denied\"}";
        writeJson(conn.stream, 403, body);
        return;
    }

    // Protocol enablement check
    if (std.mem.startsWith(u8, req.path, "/graphql") and !args.cfg.graphql_enabled) {
        writeJson(conn.stream, 404,
            "{\"error\":\"GraphQL protocol is disabled\",\"hint\":\"Set ENABLE_GRAPHQL=true\"}");
        return;
    }
    if (std.mem.startsWith(u8, req.path, "/api/v1/") and
        !std.mem.startsWith(u8, req.path, "/api/v1/health") and
        !args.cfg.rest_enabled)
    {
        writeJson(conn.stream, 404,
            "{\"error\":\"REST protocol is disabled\",\"hint\":\"Set ENABLE_REST=true\"}");
        return;
    }

    // Route and resolve
    var out_buf: [131072]u8 = undefined;

    if (std.mem.startsWith(u8, req.path, "/graphql")) {
        if (!std.ascii.eqlIgnoreCase(req.method, "POST")) {
            writeJson(conn.stream, 200,
                "{\"errors\":[{\"message\":\"GraphQL endpoint requires POST method\"}]}");
            return;
        }
        // Read POST body
        var body_storage: [65536]u8 = undefined;
        var post_body: []const u8 = "";
        if (req.content_length > 0) {
            const to_read = @min(req.content_length, body_storage.len);
            var total: usize = 0;
            while (total < to_read) {
                const n = conn.stream.read(body_storage[total..to_read]) catch break;
                if (n == 0) break;
                total += n;
            }
            post_body = body_storage[0..total];
        }

        // Extract "query" field from {"query":"..."}
        const query = blk: {
            if (std.mem.indexOf(u8, post_body, "\"query\"")) |_| {
                // Use the jsonFieldStr helper
                var kbuf: [64]u8 = undefined;
                const needle = std.fmt.bufPrint(&kbuf, "\"query\"", .{}) catch break :blk post_body;
                const kpos = std.mem.indexOf(u8, post_body, needle) orelse break :blk post_body;
                const after = post_body[kpos + needle.len ..];
                const colon = std.mem.indexOfScalar(u8, after, ':') orelse break :blk post_body;
                var rest = std.mem.trimLeft(u8, after[colon + 1 ..], " \t\n\r");
                if (rest.len == 0 or rest[0] != '"') break :blk post_body;
                rest = rest[1..];
                const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse break :blk post_body;
                break :blk rest[0..q2];
            }
            break :blk post_body;
        };

        if (query.len == 0) {
            writeJson(conn.stream, 200,
                "{\"errors\":[{\"message\":\"Missing query field in request body\"}]}");
            return;
        }

        const body = res.resolveGraphqlQuery(query, args.redis, &args.verisimdb, policy, &out_buf, arena);
        writeJson(conn.stream, 200, body);

    } else if (std.mem.startsWith(u8, req.path, "/api/v1/telemetry")) {
        const body = res.resolveTelemetry(args.redis, policy, &out_buf, arena);
        writeJson(conn.stream, 200, body);

    } else if (std.mem.startsWith(u8, req.path, "/api/v1/routes")) {
        const target = queryParam(req.raw_path, "target");
        if (target.len == 0) {
            writeJson(conn.stream, 200,
                "{\"error\":\"Missing required query parameter: target\"," ++
                "\"usage\":\"/api/v1/routes?target=<ip_or_hostname>\"}");
            return;
        }
        const body = res.resolveRouteForensics(target, args.redis, policy, &out_buf, arena);
        writeJson(conn.stream, 200, body);

    } else if (std.mem.startsWith(u8, req.path, "/api/v1/audit/temporal")) {
        const mode = queryParam(req.raw_path, "mode");
        if (mode.len == 0) {
            writeJson(conn.stream, 200,
                "{\"error\":\"Missing required query parameter: mode\"," ++
                "\"usage\":\"/api/v1/audit/temporal?mode=as_of&time=2026-02-28T12:00:00Z\"," ++
                "\"available_modes\":[\"as_of\",\"between\",\"history\"]}");
            return;
        }
        const limit_str = queryParam(req.raw_path, "limit");
        const limit: u32 = std.fmt.parseInt(u32, limit_str, 10) catch 50;
        const params = res.TemporalParams{
            .time     = queryParam(req.raw_path, "time"),
            .start    = queryParam(req.raw_path, "start"),
            .end      = queryParam(req.raw_path, "end"),
            .event_id = queryParam(req.raw_path, "event_id"),
            .limit    = limit,
        };
        const body = res.resolveTemporalAudit(mode, params, args.redis, &args.verisimdb, policy, &out_buf, arena);
        writeJson(conn.stream, 200, body);

    } else if (std.mem.startsWith(u8, req.path, "/api/v1/audit")) {
        const limit_str = queryParam(req.raw_path, "limit");
        const limit: u32 = std.fmt.parseInt(u32, limit_str, 10) catch 50;
        const body = res.resolveAudit(limit, args.redis, policy, &out_buf, arena);
        writeJson(conn.stream, 200, body);

    } else if (std.mem.startsWith(u8, req.path, "/api/v1/smokeping")) {
        const target = queryParam(req.raw_path, "target");
        if (target.len == 0) {
            writeJson(conn.stream, 200,
                "{\"error\":\"Missing required query parameter: target\"," ++
                "\"usage\":\"/api/v1/smokeping?target=<hostname_or_ip>\"}");
            return;
        }
        const body = res.resolveSmokeping(target, args.redis, policy, &out_buf, arena);
        writeJson(conn.stream, 200, body);

    } else if (std.mem.startsWith(u8, req.path, "/api/v1/health")) {
        var hbuf: [512]u8 = undefined;
        const body = healthJson(args.cfg, &hbuf);
        writeJson(conn.stream, 200, body);

    } else {
        var nbuf: [1024]u8 = undefined;
        const body = notFoundJson(args.cfg, &nbuf);
        writeJson(conn.stream, 404, body);
    }
}

// ---------------------------------------------------------------------------
// gRPC listener (Phase 1: length-prefixed JSON over TCP)
// ---------------------------------------------------------------------------

const GrpcArgs = struct {
    port:      u16,
    redis:     *rc.RedisClient,
    verisimdb: vc.VerisimDBClient,
    alloc:     std.mem.Allocator,
};

fn grpcListener(args: GrpcArgs) void {
    const addr = std.net.Address.parseIp4("0.0.0.0", args.port) catch {
        std.debug.print("[aerie] gRPC: invalid address for port {d}\n", .{args.port});
        return;
    };
    var server = addr.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("[aerie] gRPC: failed to bind port {d}: {s}\n",
            .{ args.port, @errorName(err) });
        return;
    };
    defer server.deinit();
    std.debug.print("[aerie] gRPC listener ready on :{d}\n", .{args.port});

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("[aerie] gRPC: accept error: {s}\n", .{@errorName(err)});
            continue;
        };
        const conn_args = GrpcConnArgs{
            .stream    = conn.stream,
            .redis     = args.redis,
            .verisimdb = args.verisimdb,
            .alloc     = args.alloc,
        };
        const thread = std.Thread.spawn(.{}, handleGrpcConn, .{conn_args}) catch {
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

const GrpcConnArgs = struct {
    stream:    std.net.Stream,
    redis:     *rc.RedisClient,
    verisimdb: vc.VerisimDBClient,
    alloc:     std.mem.Allocator,
};

/// Handle a single gRPC connection.
///
/// Phase 1 protocol:
///   Request:  4-byte big-endian length + JSON body
///   Response: 4-byte big-endian length + JSON body
///
/// JSON body: {"method":"GetTelemetrySnapshot"} etc.
fn handleGrpcConn(args: GrpcConnArgs) void {
    defer args.stream.close();

    var arena_inst = std.heap.ArenaAllocator.init(args.alloc);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Read 4-byte big-endian length prefix
    var len_buf: [4]u8 = undefined;
    const ln = args.stream.read(&len_buf) catch {
        std.debug.print("[aerie] gRPC: failed to read length prefix\n", .{});
        return;
    };
    if (ln < 4) return;

    const msg_len: u32 = (@as(u32, len_buf[0]) << 24) |
                         (@as(u32, len_buf[1]) << 16) |
                         (@as(u32, len_buf[2]) << 8)  |
                         @as(u32, len_buf[3]);

    if (msg_len == 0 or msg_len > 65536) {
        std.debug.print("[aerie] gRPC: invalid message length {d}\n", .{msg_len});
        return;
    }

    const body_storage = arena.alloc(u8, msg_len) catch return;
    var total: usize = 0;
    while (total < msg_len) {
        const n = args.stream.read(body_storage[total..msg_len]) catch break;
        if (n == 0) break;
        total += n;
    }
    const body = body_storage[0..total];

    // Extract "method" field
    const method = blk: {
        var nb: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&nb, "\"method\"", .{}) catch break :blk "";
        const kpos   = std.mem.indexOf(u8, body, needle) orelse break :blk "";
        const after  = body[kpos + needle.len ..];
        const colon  = std.mem.indexOfScalar(u8, after, ':') orelse break :blk "";
        var rest     = std.mem.trimLeft(u8, after[colon + 1 ..], " \t");
        if (rest.len == 0 or rest[0] != '"') break :blk "";
        rest = rest[1..];
        const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse break :blk "";
        break :blk rest[0..q2];
    };

    const policy = pol.evaluatePolicy("", method);

    var out_buf: [131072]u8 = undefined;

    const response: []const u8 = blk: {
        if (std.mem.eql(u8, method, "GetTelemetrySnapshot")) {
            break :blk res.resolveTelemetry(args.redis, policy, &out_buf, arena);
        }
        if (std.mem.eql(u8, method, "GetRouteForensicsSnapshot")) {
            const target = jsonStrField(body, "target") orelse
                break :blk "{\"error\":\"target field required\"}";
            break :blk res.resolveRouteForensics(target, args.redis, policy, &out_buf, arena);
        }
        if (std.mem.eql(u8, method, "GetAuditSnapshot")) {
            const limit = jsonIntField(body, "limit") orelse @as(u32, 50);
            break :blk res.resolveAudit(limit, args.redis, policy, &out_buf, arena);
        }
        if (std.mem.eql(u8, method, "GetSmokePingSnapshot")) {
            const target = jsonStrField(body, "target") orelse
                break :blk "{\"error\":\"target field required\"}";
            break :blk res.resolveSmokeping(target, args.redis, policy, &out_buf, arena);
        }
        if (std.mem.eql(u8, method, "GetTemporalAuditSnapshot")) {
            const mode = jsonStrField(body, "mode") orelse
                break :blk "{\"error\":\"mode field required (as_of, between, history)\"}";
            const limit_raw = jsonIntField(body, "limit") orelse @as(u32, 50);
            const params = res.TemporalParams{
                .time     = jsonStrField(body, "time")     orelse "",
                .start    = jsonStrField(body, "start")    orelse "",
                .end      = jsonStrField(body, "end")      orelse "",
                .event_id = jsonStrField(body, "event_id") orelse "",
                .limit    = limit_raw,
            };
            break :blk res.resolveTemporalAudit(
                mode, params, args.redis, &args.verisimdb, policy, &out_buf, arena);
        }
        var eb: [256]u8 = undefined;
        break :blk std.fmt.bufPrint(&eb,
            "{{\"error\":\"Unknown method: {s}\"," ++
            "\"available\":[\"GetTelemetrySnapshot\",\"GetRouteForensicsSnapshot\"," ++
            "\"GetAuditSnapshot\",\"GetSmokePingSnapshot\",\"GetTemporalAuditSnapshot\"]}}",
            .{method},
        ) catch "{\"error\":\"unknown method\"}";
    };

    sendGrpcResponse(args.stream, response);
}

/// Send a 4-byte big-endian length-prefixed response.
fn sendGrpcResponse(stream: std.net.Stream, body: []const u8) void {
    const length: u32 = @intCast(body.len);
    const header: [4]u8 = .{
        @intCast((length >> 24) & 0xff),
        @intCast((length >> 16) & 0xff),
        @intCast((length >>  8) & 0xff),
        @intCast(length         & 0xff),
    };
    stream.writeAll(&header) catch {
        std.debug.print("[aerie] gRPC: failed to write response header\n", .{});
        return;
    };
    stream.writeAll(body) catch {
        std.debug.print("[aerie] gRPC: failed to write response body\n", .{});
    };
}

/// Extract a string JSON field `"key":"value"` from `data`.
/// Returns a slice into `data` (no allocation).
fn jsonStrField(data: []const u8, key: []const u8) ?[]const u8 {
    var nb: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "\"{s}\"", .{key}) catch return null;
    const kpos   = std.mem.indexOf(u8, data, needle) orelse return null;
    const after  = data[kpos + needle.len ..];
    const colon  = std.mem.indexOfScalar(u8, after, ':') orelse return null;
    var rest     = std.mem.trimLeft(u8, after[colon + 1 ..], " \t");
    if (rest.len == 0 or rest[0] != '"') return null;
    rest = rest[1..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..q2];
}

/// Extract an integer JSON field from `data`.
fn jsonIntField(data: []const u8, key: []const u8) ?u32 {
    var nb: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "\"{s}\"", .{key}) catch return null;
    const kpos   = std.mem.indexOf(u8, data, needle) orelse return null;
    const after  = data[kpos + needle.len ..];
    const colon  = std.mem.indexOfScalar(u8, after, ':') orelse return null;
    const rest   = std.mem.trimLeft(u8, after[colon + 1 ..], " \t");
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

// ---------------------------------------------------------------------------
// HTTP server thread
// ---------------------------------------------------------------------------

const HttpArgs = struct {
    port:      u16,
    cfg:       t.ProtocolConfig,
    redis:     *rc.RedisClient,
    verisimdb: vc.VerisimDBClient,
    alloc:     std.mem.Allocator,
};

fn httpListener(args: HttpArgs) void {
    const addr = std.net.Address.parseIp4("0.0.0.0", args.port) catch {
        std.debug.print("[aerie] HTTP: invalid address for port {d}\n", .{args.port});
        return;
    };
    var server = addr.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("[aerie] HTTP: failed to bind port {d}: {s}\n",
            .{ args.port, @errorName(err) });
        return;
    };
    defer server.deinit();
    std.debug.print("[aerie] HTTP server ready on :{d}\n", .{args.port});

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("[aerie] HTTP: accept error: {s}\n", .{@errorName(err)});
            continue;
        };
        const cargs = ConnArgs{
            .conn      = conn,
            .cfg       = args.cfg,
            .redis     = args.redis,
            .verisimdb = args.verisimdb,
            .alloc     = args.alloc,
        };
        const thread = std.Thread.spawn(.{}, handleHttpConn, .{cargs}) catch {
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa_inst = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_inst.deinit();
    const gpa = gpa_inst.allocator();

    // Ports
    const port_str      = std.posix.getenv("PORT")      orelse "4000";
    const grpc_port_str = std.posix.getenv("GRPC_PORT") orelse "4001";
    const http_port     = std.fmt.parseInt(u16, port_str,      10) catch 4000;
    const grpc_port     = std.fmt.parseInt(u16, grpc_port_str, 10) catch 4001;

    const cfg = readProtocolConfig();
    printBanner(http_port, grpc_port, cfg);

    // Shared state — allocated on heap so threads can hold pointers safely
    const redis_ptr = try gpa.create(rc.RedisClient);
    redis_ptr.* = rc.RedisClient.init(gpa);
    defer { redis_ptr.deinit(); gpa.destroy(redis_ptr); }

    const verisimdb = vc.VerisimDBClient.init();

    // Start gRPC in a background thread (only if enabled)
    if (cfg.grpc_enabled) {
        std.debug.print("[aerie] Starting gRPC listener on :{d}\n", .{grpc_port});
        const grpc_thread = try std.Thread.spawn(.{}, grpcListener, .{GrpcArgs{
            .port      = grpc_port,
            .redis     = redis_ptr,
            .verisimdb = verisimdb,
            .alloc     = gpa,
        }});
        grpc_thread.detach();
    } else {
        std.debug.print("[aerie] gRPC DISABLED — port {d} not bound\n", .{grpc_port});
    }

    // Start HTTP server (only if REST or GraphQL is enabled)
    const http_needed = cfg.rest_enabled or cfg.graphql_enabled;
    if (http_needed) {
        std.debug.print("[aerie] Starting HTTP server on :{d}\n", .{http_port});
        httpListener(.{
            .port      = http_port,
            .cfg       = cfg,
            .redis     = redis_ptr,
            .verisimdb = verisimdb,
            .alloc     = gpa,
        });
    } else {
        std.debug.print("[aerie] REST and GraphQL both DISABLED — port {d} not bound\n",
            .{http_port});
        if (cfg.grpc_enabled) {
            std.debug.print("[aerie] Main thread idle (gRPC-only mode)\n", .{});
            // Block main thread — gRPC thread keeps the process alive
            while (true) std.Thread.sleep(60 * std.time.ns_per_s);
        } else {
            std.debug.print(
                "[aerie] WARNING: All protocols disabled — gateway has nothing to serve\n", .{});
        }
    }
}
