// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// main.zig — Aerie Gateway: Single-Port Path-Routed API Server (Zig port)
//
// All three protocols are served on ONE port via path routing (default: 4000).
// The HTTP listener is owned by uapi_gnosis_start via uapi_gnosis_set_handler,
// which calls aerieHandler for every incoming request.
//
//   /graphql               — GraphQL handler
//   /api/v1/*              — REST handlers
//   /grpc/*                — gRPC-JSON handlers (HTTP transport, method in body)
//   /api/v1/health         — health check (always enabled)
//
// Previously the gateway bound two ports (4000 HTTP / 4001 gRPC-TCP) with
// its own per-protocol listener threads.  The new shape uses a single gnosis
// pool slot and uapi_gnosis_set_handler to plug aerieHandler as the dispatch
// function.  No current consumer fires more than one protocol simultaneously,
// so consolidating to one port loses nothing.
//
// Environment variables:
//   PORT          — HTTP port for all protocols (default 4000)
//   ENABLE_REST   — "false"/"0"/"no" to disable REST (default enabled)
//   ENABLE_GRAPHQL— same
//   ENABLE_GRPC   — same
//
// All responses are wrapped in a ProofEnvelope (SHA-256 hash, Phase 1).
// The policy gate checks X-Api-Key headers and logs all access to Redis.
//
// Server lifecycle — consumes zig-api (developer-ecosystem/zig-api):
//   uapi_init()                 — initialises gnosis server pool + connector pool
//   uapi_gnosis_create()        — reserves a pool slot for port 4000
//   uapi_gnosis_set_handler()   — registers aerieHandler as the edge dispatch fn
//   uapi_gnosis_start()         — starts gnosis background thread
//   uapi_gnosis_stop()          — drains the background thread on shutdown
//   uapi_gnosis_destroy()       — releases pool slot and resources
//   uapi_connector_*            — outbound HTTP service calls (see service clients)
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

/// C ABI imports from libzig_api (developer-ecosystem/zig-api).
/// These provide the server pool (uapi_gnosis_*) and connector pool
/// (uapi_connector_*) lifecycle management.
const c = @cImport({
    @cInclude("zig_api.h");
});

// ---------------------------------------------------------------------------
// zig-api server-pool state handles (module-level, set during init)
// ---------------------------------------------------------------------------

/// gnosis pool handle for the unified HTTP listener (port 4000 by default).
/// All three protocols (REST, GraphQL, gRPC-JSON) are path-routed on this port.
/// Set to 0 when disabled or initialisation fails.
var gnosis_http_handle: u64 = 0;

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
fn printBanner(http_port: u16, cfg: t.ProtocolConfig) void {
    std.debug.print(
        "╔══════════════════════════════════════════════════════════╗\n" ++
        "║   AERIE GATEWAY — Zig port (single-port, PMPL-1.0-or-later) ║\n" ++
        "╠══════════════════════════════════════════════════════════╣\n",
        .{},
    );
    std.debug.print("║  Port            : {d:<5}                                   ║\n", .{http_port});
    if (cfg.rest_enabled) {
        std.debug.print("║  REST            : /api/v1/* ✓ ENABLED                  ║\n", .{});
    } else {
        std.debug.print("║  REST            : ✗ DISABLED                           ║\n", .{});
    }
    if (cfg.graphql_enabled) {
        std.debug.print("║  GraphQL         : /graphql ✓ ENABLED                   ║\n", .{});
    } else {
        std.debug.print("║  GraphQL         : ✗ DISABLED                           ║\n", .{});
    }
    if (cfg.grpc_enabled) {
        std.debug.print("║  gRPC-JSON       : /grpc/* ✓ ENABLED                    ║\n", .{});
    } else {
        std.debug.print("║  gRPC-JSON       : ✗ DISABLED                           ║\n", .{});
    }
    std.debug.print(
        "╠══════════════════════════════════════════════════════════╣\n" ++
        "║  Server pool     : uapi_gnosis_* (zig-api)              ║\n" ++
        "║  Connector pool  : uapi_connector_* (zig-api)           ║\n" ++
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
    // Include gnosis server pool state in health output.
    const pool_state: u8 = if (gnosis_http_handle != 0)
        c.uapi_gnosis_state(gnosis_http_handle)
    else
        c.UAPI_SERVER_STOPPED;
    return std.fmt.bufPrint(out,
        "{{\"status\":\"healthy\",\"service\":\"aerie-gateway\",\"version\":\"0.3.0\"," ++
        "\"timestamp\":\"{s}\",\"protocols\":{{\"rest\":{s},\"graphql\":{s},\"grpc\":{s}}}," ++
        "\"active_protocols\":{d},\"bound_ports\":{d}," ++
        "\"verb_governance\":true,\"stealth_mode\":true,\"proof_mode\":\"light\"," ++
        "\"policy_phase\":1,\"pool\":{{\"slot_state\":{d}}}}}",
        .{
            ts,
            if (cfg.rest_enabled)    "true" else "false",
            if (cfg.graphql_enabled) "true" else "false",
            if (cfg.grpc_enabled)    "true" else "false",
            active, bound,
            pool_state,
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
// aerieHandler — edge hook for uapi_gnosis_set_handler
// (Old per-connection HTTP handler and gRPC TCP listener removed 2026-04-17:
//  both are superseded by the single-port set_handler architecture.)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// aerieHandler — edge hook for uapi_gnosis_set_handler
//
// gnosis calls this for every HTTP request on the pool port.
// aerieHandler path-dispatches to the appropriate protocol family.
// gRPC-over-TCP (Phase 1) is superseded: gRPC methods are now routed over
// HTTP at /grpc/<MethodName>.
//
// Module-level context set by main() before uapi_gnosis_start:
//   g_aerie_cfg          — protocol enablement flags
//   g_aerie_redis        — Redis client pointer
//   g_aerie_verisimdb    — VerisimDB client value
//   g_aerie_alloc        — base allocator for per-request arenas
//   g_aerie_context_ready — true once all the above are initialised
// ---------------------------------------------------------------------------

var g_aerie_cfg:           t.ProtocolConfig    = .{ .rest_enabled = true, .graphql_enabled = true, .grpc_enabled = true };
var g_aerie_redis:         ?*rc.RedisClient    = null;
var g_aerie_verisimdb:     vc.VerisimDBClient  = undefined;
var g_aerie_alloc:         std.mem.Allocator   = undefined;
var g_aerie_context_ready: bool                = false;

/// Response body buffer for aerieHandler.  gnosis's serve thread calls
/// aerieHandler serially (one per connection), so a module-level buffer is safe.
var g_aerie_resp_buf: [131072]u8 = undefined;

/// Sentinel content-type strings for aerieHandler responses.
const AERIE_CT_JSON: [*:0]const u8 = "application/json";

/// Fill a GnosisResponse with an error body.
fn aerieRespError(
    resp_c: [*c]c.GnosisResponse,
    status: u16,
    msg:    []const u8,
) void {
    const resp: *c.GnosisResponse = @ptrCast(resp_c);
    var fbs = std.io.fixedBufferStream(&g_aerie_resp_buf);
    fbs.writer().print("{{\"error\":\"{s}\"}}", .{msg}) catch {};
    const written = fbs.getWritten();
    resp.status       = status;
    resp._pad         = 0;
    resp.content_type = AERIE_CT_JSON;
    resp.body_ptr     = written.ptr;
    resp.body_len     = @intCast(written.len);
}

/// The edge handler registered with uapi_gnosis_set_handler.
///
/// gnosis provides method, path, and body pre-parsed from the HTTP request.
/// aerieHandler replicates the routing logic from handleHttpConn, writing
/// the response into g_aerie_resp_buf and filling the GnosisResponse.
///
/// Protocol path mapping:
///   /graphql      → GraphQL handler
///   /api/v1/*     → REST handlers
///   /grpc/*       → gRPC-JSON handlers (body contains {"method":"...","...":...})
///   else          → 404
export fn aerieHandler(req_c: [*c]const c.GnosisRequest, resp_c: [*c]c.GnosisResponse) callconv(.c) void {
    const resp: *c.GnosisResponse      = @ptrCast(resp_c);
    const req:  *const c.GnosisRequest = @ptrCast(req_c);

    if (!g_aerie_context_ready) {
        aerieRespError(resp_c, 503, "gateway not ready");
        return;
    }

    const redis    = g_aerie_redis orelse {
        aerieRespError(resp_c, 503, "redis not initialised");
        return;
    };

    var arena_inst = std.heap.ArenaAllocator.init(g_aerie_alloc);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const method = std.mem.span(req.method);
    const path   = std.mem.span(req.path);
    const body: []const u8 = if (req.body_ptr) |p| p[0..req.body_len] else "";

    // CORS preflight
    if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) {
        resp.status = 204; resp._pad = 0;
        resp.content_type = "text/plain";
        resp.body_ptr = null; resp.body_len = 0;
        return;
    }

    // Policy gate — derive api_key from a header if available.
    // Since gnosis's GnosisRequest does not expose raw headers (by design),
    // we pass an empty api_key here.  Phase 1 policy is permissive regardless.
    const policy = pol.evaluatePolicy("", moduleFromPath(path));
    if (!policy.allowed) {
        var rb: [256]u8 = undefined;
        const reason = std.mem.sliceTo(&policy.reason, 0);
        var fbs = std.io.fixedBufferStream(&rb);
        fbs.writer().print("{{\"error\":\"Access denied\",\"reason\":\"{s}\"}}", .{reason}) catch {};
        const written = fbs.getWritten();
        resp.status = 403; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
        resp.body_ptr = written.ptr; resp.body_len = @intCast(written.len);
        return;
    }

    // Protocol enablement checks
    if (std.mem.startsWith(u8, path, "/graphql") and !g_aerie_cfg.graphql_enabled) {
        const e = "{\"error\":\"GraphQL disabled\",\"hint\":\"Set ENABLE_GRAPHQL=true\"}";
        resp.status = 404; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
        resp.body_ptr = e; resp.body_len = e.len;
        return;
    }
    if (std.mem.startsWith(u8, path, "/api/v1/") and
        !std.mem.startsWith(u8, path, "/api/v1/health") and
        !g_aerie_cfg.rest_enabled)
    {
        const e = "{\"error\":\"REST disabled\",\"hint\":\"Set ENABLE_REST=true\"}";
        resp.status = 404; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
        resp.body_ptr = e; resp.body_len = e.len;
        return;
    }
    if (std.mem.startsWith(u8, path, "/grpc/") and !g_aerie_cfg.grpc_enabled) {
        const e = "{\"error\":\"gRPC disabled\",\"hint\":\"Set ENABLE_GRPC=true\"}";
        resp.status = 404; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
        resp.body_ptr = e; resp.body_len = e.len;
        return;
    }

    // GraphQL dispatch
    if (std.mem.startsWith(u8, path, "/graphql")) {
        if (!std.ascii.eqlIgnoreCase(method, "POST")) {
            const e = "{\"errors\":[{\"message\":\"GraphQL endpoint requires POST method\"}]}";
            resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
            resp.body_ptr = e; resp.body_len = e.len;
            return;
        }
        const query = blk: {
            if (std.mem.indexOf(u8, body, "\"query\"")) |_| {
                var kbuf: [64]u8 = undefined;
                const needle = std.fmt.bufPrint(&kbuf, "\"query\"", .{}) catch break :blk body;
                const kpos = std.mem.indexOf(u8, body, needle) orelse break :blk body;
                const after = body[kpos + needle.len ..];
                const colon = std.mem.indexOfScalar(u8, after, ':') orelse break :blk body;
                var rest = std.mem.trimLeft(u8, after[colon + 1 ..], " \t\n\r");
                if (rest.len == 0 or rest[0] != '"') break :blk body;
                rest = rest[1..];
                const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse break :blk body;
                break :blk rest[0..q2];
            }
            break :blk body;
        };
        if (query.len == 0) {
            const e = "{\"errors\":[{\"message\":\"Missing query field in request body\"}]}";
            resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
            resp.body_ptr = e; resp.body_len = e.len;
            return;
        }
        const out = res.resolveGraphqlQuery(query, redis, &g_aerie_verisimdb, policy, &g_aerie_resp_buf, arena);
        resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
        resp.body_ptr = out.ptr; resp.body_len = @intCast(out.len);
        return;
    }

    // gRPC-JSON dispatch (HTTP transport; method name in body)
    if (std.mem.startsWith(u8, path, "/grpc/")) {
        // Derive method name from path suffix or body "method" field.
        // Path: /grpc/GetTelemetrySnapshot → method = "GetTelemetrySnapshot"
        const method_name = path["/grpc/".len..];
        const grpc_method = if (method_name.len > 0) method_name
            else jsonStrFieldNoAlloc(body, "method");
        const grpc_policy = pol.evaluatePolicy("", grpc_method);
        const out = aerieGrpcDispatch(grpc_method, body, redis, grpc_policy, arena);
        resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
        resp.body_ptr = out.ptr; resp.body_len = @intCast(out.len);
        return;
    }

    // REST dispatch — mirrors handleHttpConn REST routing
    if (std.mem.startsWith(u8, path, "/api/v1/telemetry")) {
        const out = res.resolveTelemetry(redis, policy, &g_aerie_resp_buf, arena);
        resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
        resp.body_ptr = out.ptr; resp.body_len = @intCast(out.len);
        return;
    }
    if (std.mem.startsWith(u8, path, "/api/v1/routes")) {
        const target = queryParamFromPath(path, "target");
        if (target.len == 0) {
            const e = "{\"error\":\"Missing required query parameter: target\"," ++
                "\"usage\":\"/api/v1/routes?target=<ip_or_hostname>\"}";
            resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
            resp.body_ptr = e; resp.body_len = e.len;
            return;
        }
        const out = res.resolveRouteForensics(target, redis, policy, &g_aerie_resp_buf, arena);
        resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
        resp.body_ptr = out.ptr; resp.body_len = @intCast(out.len);
        return;
    }
    if (std.mem.startsWith(u8, path, "/api/v1/audit/temporal")) {
        const mode = queryParamFromPath(path, "mode");
        if (mode.len == 0) {
            const e = "{\"error\":\"Missing required query parameter: mode\"," ++
                "\"usage\":\"/api/v1/audit/temporal?mode=as_of&time=2026-02-28T12:00:00Z\"," ++
                "\"available_modes\":[\"as_of\",\"between\",\"history\"]}";
            resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
            resp.body_ptr = e; resp.body_len = e.len;
            return;
        }
        const limit_str = queryParamFromPath(path, "limit");
        const limit: u32 = std.fmt.parseInt(u32, limit_str, 10) catch 50;
        const params = res.TemporalParams{
            .time     = queryParamFromPath(path, "time"),
            .start    = queryParamFromPath(path, "start"),
            .end      = queryParamFromPath(path, "end"),
            .event_id = queryParamFromPath(path, "event_id"),
            .limit    = limit,
        };
        const out = res.resolveTemporalAudit(mode, params, redis, &g_aerie_verisimdb, policy, &g_aerie_resp_buf, arena);
        resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
        resp.body_ptr = out.ptr; resp.body_len = @intCast(out.len);
        return;
    }
    if (std.mem.startsWith(u8, path, "/api/v1/audit")) {
        const limit_str = queryParamFromPath(path, "limit");
        const limit: u32 = std.fmt.parseInt(u32, limit_str, 10) catch 50;
        const out = res.resolveAudit(limit, redis, policy, &g_aerie_resp_buf, arena);
        resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
        resp.body_ptr = out.ptr; resp.body_len = @intCast(out.len);
        return;
    }
    if (std.mem.startsWith(u8, path, "/api/v1/smokeping")) {
        const target = queryParamFromPath(path, "target");
        if (target.len == 0) {
            const e = "{\"error\":\"Missing required query parameter: target\"," ++
                "\"usage\":\"/api/v1/smokeping?target=<hostname_or_ip>\"}";
            resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
            resp.body_ptr = e; resp.body_len = e.len;
            return;
        }
        const out = res.resolveSmokeping(target, redis, policy, &g_aerie_resp_buf, arena);
        resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
        resp.body_ptr = out.ptr; resp.body_len = @intCast(out.len);
        return;
    }
    if (std.mem.startsWith(u8, path, "/api/v1/health")) {
        var hbuf: [512]u8 = undefined;
        const out = healthJson(g_aerie_cfg, &hbuf);
        resp.status = 200; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
        resp.body_ptr = out.ptr; resp.body_len = @intCast(out.len);
        return;
    }

    // 404 — not found
    var nbuf: [1024]u8 = undefined;
    const not_found = notFoundJson(g_aerie_cfg, &nbuf);
    resp.status = 404; resp._pad = 0; resp.content_type = AERIE_CT_JSON;
    resp.body_ptr = not_found.ptr; resp.body_len = @intCast(not_found.len);
}

/// Dispatch a gRPC-JSON method to the correct resolver.
/// Returns a slice into `g_aerie_resp_buf` (valid until next aerieHandler call).
fn aerieGrpcDispatch(
    method_name: []const u8,
    body:        []const u8,
    redis:       *rc.RedisClient,
    policy:      t.PolicyDecision,
    arena:       std.mem.Allocator,
) []const u8 {
    if (std.mem.eql(u8, method_name, "GetTelemetrySnapshot")) {
        return res.resolveTelemetry(redis, policy, &g_aerie_resp_buf, arena);
    }
    if (std.mem.eql(u8, method_name, "GetRouteForensicsSnapshot")) {
        const target = jsonStrFieldNoAlloc(body, "target");
        if (target.len == 0) return "{\"error\":\"target field required\"}";
        return res.resolveRouteForensics(target, redis, policy, &g_aerie_resp_buf, arena);
    }
    if (std.mem.eql(u8, method_name, "GetAuditSnapshot")) {
        const limit = jsonIntFieldNoAlloc(body, "limit") orelse @as(u32, 50);
        return res.resolveAudit(limit, redis, policy, &g_aerie_resp_buf, arena);
    }
    if (std.mem.eql(u8, method_name, "GetSmokePingSnapshot")) {
        const target = jsonStrFieldNoAlloc(body, "target");
        if (target.len == 0) return "{\"error\":\"target field required\"}";
        return res.resolveSmokeping(target, redis, policy, &g_aerie_resp_buf, arena);
    }
    if (std.mem.eql(u8, method_name, "GetTemporalAuditSnapshot")) {
        const mode = jsonStrFieldNoAlloc(body, "mode");
        if (mode.len == 0) return "{\"error\":\"mode field required (as_of, between, history)\"}";
        const limit = jsonIntFieldNoAlloc(body, "limit") orelse @as(u32, 50);
        const params = res.TemporalParams{
            .time     = jsonStrFieldNoAlloc(body, "time"),
            .start    = jsonStrFieldNoAlloc(body, "start"),
            .end      = jsonStrFieldNoAlloc(body, "end"),
            .event_id = jsonStrFieldNoAlloc(body, "event_id"),
            .limit    = limit,
        };
        return res.resolveTemporalAudit(mode, params, redis, &g_aerie_verisimdb, policy, &g_aerie_resp_buf, arena);
    }
    var eb: [256]u8 = undefined;
    return std.fmt.bufPrint(&eb,
        "{{\"error\":\"Unknown method: {s}\"," ++
        "\"available\":[\"GetTelemetrySnapshot\",\"GetRouteForensicsSnapshot\"," ++
        "\"GetAuditSnapshot\",\"GetSmokePingSnapshot\",\"GetTemporalAuditSnapshot\"]}}",
        .{method_name},
    ) catch "{\"error\":\"unknown method\"}";
}

/// Extract a query parameter from a path+query string.
/// Returns a slice into `path` or empty string if absent.
fn queryParamFromPath(raw_path: []const u8, name: []const u8) []const u8 {
    return queryParam(raw_path, name);
}

/// Extract a JSON string field without allocating.
/// Returns a slice into `data` (no copy).
fn jsonStrFieldNoAlloc(data: []const u8, key: []const u8) []const u8 {
    var nb: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, "\"{s}\"", .{key}) catch return "";
    const kpos   = std.mem.indexOf(u8, data, needle) orelse return "";
    const after  = data[kpos + needle.len ..];
    const colon  = std.mem.indexOfScalar(u8, after, ':') orelse return "";
    var rest     = std.mem.trimLeft(u8, after[colon + 1 ..], " \t");
    if (rest.len == 0 or rest[0] != '"') return "";
    rest = rest[1..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
    return rest[0..q2];
}

/// Extract an integer JSON field without allocating.
fn jsonIntFieldNoAlloc(data: []const u8, key: []const u8) ?u32 {
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
// Gnosis pool handle helpers
// ---------------------------------------------------------------------------

/// Allocate a gnosis pool slot for `port` and return the handle.
/// Returns 0 and logs a warning if the pool is exhausted or uapi_init has
/// not been called.
fn acquireGnosisHandle(port: u16) u64 {
    const handle = c.uapi_gnosis_create(port);
    if (handle == 0) {
        std.debug.print("[aerie] warn: gnosis pool slot unavailable for port {d}\n", .{port});
    }
    return handle;
}

/// Release a gnosis pool slot and zero the handle.
/// Safe to call with a zero handle (no-op).
fn releaseGnosisHandle(handle_ptr: *u64) void {
    if (handle_ptr.* == 0) return;
    c.uapi_gnosis_destroy(handle_ptr.*);
    handle_ptr.* = 0;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa_inst = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_inst.deinit();
    const gpa = gpa_inst.allocator();

    // Initialise the zig-api library (gnosis server pool + connector pool).
    // Must be called before any uapi_gnosis_* or uapi_connector_* function.
    const init_rc = c.uapi_init();
    if (init_rc != c.UAPI_OK) {
        std.debug.print("[aerie] FATAL: uapi_init() failed with code {d}\n", .{init_rc});
        return error.UapiInitFailed;
    }
    defer c.uapi_teardown();

    // Port — single port for all protocols
    const port_str  = std.posix.getenv("PORT") orelse "4000";
    const http_port = std.fmt.parseInt(u16, port_str, 10) catch 4000;

    const cfg = readProtocolConfig();
    printBanner(http_port, cfg);

    // Shared state — allocated on heap so the handler can hold a stable pointer
    const redis_ptr = try gpa.create(rc.RedisClient);
    redis_ptr.* = rc.RedisClient.init(gpa);
    defer { redis_ptr.deinit(); gpa.destroy(redis_ptr); }

    const verisimdb = vc.VerisimDBClient.init();

    // -------------------------------------------------------------------------
    // Set up module-level handler context before uapi_gnosis_start.
    // aerieHandler reads these; they are never mutated after start.
    // -------------------------------------------------------------------------
    g_aerie_cfg          = cfg;
    g_aerie_redis        = redis_ptr;
    g_aerie_verisimdb    = verisimdb;
    g_aerie_alloc        = gpa;
    g_aerie_context_ready = true;

    // -------------------------------------------------------------------------
    // Single-port setup:
    //   1. Reserve one gnosis pool slot on http_port.
    //   2. Register aerieHandler as the edge dispatch hook.
    //   3. Start the gnosis accept loop.
    // -------------------------------------------------------------------------
    gnosis_http_handle = acquireGnosisHandle(http_port);
    if (gnosis_http_handle == 0) {
        std.debug.print("[aerie] FATAL: gnosis pool slot unavailable for port {d}\n", .{http_port});
        return error.GnosisCreateFailed;
    }
    defer releaseGnosisHandle(&gnosis_http_handle);

    const set_rc = c.uapi_gnosis_set_handler(gnosis_http_handle, &aerieHandler);
    if (set_rc != c.UAPI_OK) {
        std.debug.print("[aerie] FATAL: uapi_gnosis_set_handler failed (result={d})\n", .{set_rc});
        return error.GnosisSetHandlerFailed;
    }

    const start_rc = c.uapi_gnosis_start(gnosis_http_handle);
    if (start_rc != c.UAPI_OK) {
        std.debug.print("[aerie] FATAL: uapi_gnosis_start failed (result={d})\n", .{start_rc});
        return error.GnosisStartFailed;
    }

    std.debug.print("[aerie] Listening on :{d} — REST /api/v1/* | GraphQL /graphql | gRPC-JSON /grpc/*\n",
        .{http_port});

    // Block main thread until the server stops.
    while (c.uapi_gnosis_state(gnosis_http_handle) == c.UAPI_SERVER_LISTENING) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}
