// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// main.zig — Aerie Gateway: lifecycle + the V2 edge handler.
//
// Phase 1 (the aspect-weave skeleton): this file shrank from a 756-line
// everything-inline handler to lifecycle only. The pipeline lives in
// router.dispatch; the request context in ctx.zig; config in config.zig
// (env + KYAML); responses in respond.zig; the error taxonomy in
// errors.zig; verb governance reads the router table.
//
// The handler registers as V2 (GnosisRequestV2): the query string and
// request headers — both stripped by the v1 surface — are real now, so
// the policy gate finally sees X-Api-Key and resolvers see ?target=
// parameters. The per-request arena replaces the shared 128 KiB static
// response buffer (the serial-handler assumption is gone).
//
// Environment (single reader: config.zig):
//   PORT, ENABLE_REST, ENABLE_GRAPHQL, ENABLE_GRPC, *_URL,
//   AERIE_CONFIG (KYAML file), AERIE_AUTH_MODE.
//
// Requires: Zig 0.15.2+

const std = @import("std");
const t = @import("types.zig");
const rc = @import("redis_client.zig");
const vc = @import("verisim_client.zig");
const config = @import("config.zig");
const ctx = @import("ctx.zig");
const router = @import("router.zig");
const respond = @import("respond.zig");
const ks = @import("keystore.zig");

/// C ABI from the in-repo FFI (declared in src/abi/Gnosis.idr).
const c = @cImport({
    @cInclude("zig_api.h");
});

// ---------------------------------------------------------------------------
// Module-level server state (set once in main, before gnosis starts)
// ---------------------------------------------------------------------------

var g_cfg: config.Config = undefined;
var g_redis: ?*rc.RedisClient = null;
var g_verisim: vc.VerisimDBClient = undefined;
var g_keystore: ks.KeyStore = undefined;
var g_alloc: std.mem.Allocator = undefined;
var g_ready: bool = false;

/// gnosis pool handle for the unified HTTP listener.
var gnosis_http_handle: u64 = 0;

// ---------------------------------------------------------------------------
// The V2 edge handler (registered via uapi_gnosis_set_handler_v2)
// ---------------------------------------------------------------------------

fn fillError(resp: [*c]c.GnosisResponse, status: u16, msg: []const u8) void {
    const body: [*]const u8 = @ptrCast(msg.ptr);
    c.uapi_gnosis_write_response(resp, status, "application/json", body, @intCast(msg.len));
}

/// The edge handler: build a per-request Ctx, dispatch, write the
/// response through the single path. Nothing else lives here — that is
/// the point of the weave.
export fn aerieHandlerV2(
    req_c: [*c]const c.GnosisRequestV2,
    resp_c: [*c]c.GnosisResponse,
) callconv(.c) void {
    const resp: *c.GnosisResponse = @ptrCast(resp_c);
    const req: *const c.GnosisRequestV2 = @ptrCast(req_c);

    if (!g_ready) {
        fillError(resp_c, 503, "{\"error\":\"gateway not ready\"}");
        return;
    }
    const redis = g_redis orelse {
        fillError(resp_c, 503, "{\"error\":\"redis not initialised\"}");
        return;
    };

    var arena_inst = std.heap.ArenaAllocator.init(g_alloc);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Response scratch provided by gnosis: it outlives this handler call
    // (the server writes to the socket after we return), unlike the
    // request arena above — response bodies live in the scratch, never
    // in the arena. (The arena serves request-lifetime allocations only.)
    const out_buf: []u8 = if (req.resp_scratch != null and req.resp_scratch_len > 0)
        req.resp_scratch[0..req.resp_scratch_len]
    else
        &.{};

    var request = ctx.Ctx{
        .arena = arena,
        .method = std.mem.span(req.method),
        .path = std.mem.span(req.path),
        .query = std.mem.span(req.query),
        .body = if (req.body_ptr) |p| p[0..req.body_len] else "",
        .header_names = if (req.header_count > 0 and req.header_names != null)
            req.header_names[0..req.header_count]
        else
            null,
        .header_values = if (req.header_count > 0 and req.header_values != null)
            req.header_values[0..req.header_count]
        else
            null,
        .header_count = req.header_count,
        .cfg = &g_cfg,
        .redis = redis,
        .verisim = &g_verisim,
        .keystore = &g_keystore,
        .pool_state = if (gnosis_http_handle != 0)
            c.uapi_gnosis_state(gnosis_http_handle)
        else
            c.UAPI_SERVER_STOPPED,
        .out_buf = out_buf,
    };

    router.dispatch(&request);

    // The single response write path.
    const body = request.resp_body;
    c.uapi_gnosis_write_response(
        resp,
        request.status,
        "application/json",
        if (body.len > 0) @as(?[*]const u8, @ptrCast(body.ptr)) else null,
        @intCast(body.len),
    );
}

// ---------------------------------------------------------------------------
// Gnosis pool handle helpers
// ---------------------------------------------------------------------------

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

    const init_rc = c.uapi_init();
    if (init_rc != c.UAPI_OK) {
        std.debug.print("[aerie] FATAL: uapi_init() failed with code {d}\n", .{init_rc});
        return error.UapiInitFailed;
    }
    defer c.uapi_teardown();

    // Configuration: typed, loaded once, the only getenv reader.
    var cfg_arena = std.heap.ArenaAllocator.init(gpa);
    defer cfg_arena.deinit();
    g_cfg = config.Config.load(cfg_arena.allocator());

    printBanner(&g_cfg);

    // Services — stable pointers for the handler's lifetime.
    const redis_ptr = try gpa.create(rc.RedisClient);
    redis_ptr.* = rc.RedisClient.init(gpa);
    defer {
        redis_ptr.deinit();
        gpa.destroy(redis_ptr);
    }
    g_verisim = vc.VerisimDBClient.init();
    g_alloc = gpa;
    g_redis = redis_ptr;

    // Keystore: env specs first, then the KYAML api_keys list.
    g_keystore = ks.KeyStore.init();
    const env_keys = g_keystore.loadFromEnvValue(g_cfg.api_keys_env);
    var yaml_keys: usize = 0;
    if (g_cfg.config_path) |path| {
        if (std.fs.cwd().readFileAlloc(cfg_arena.allocator(), path, 1 << 20)) |src| {
            yaml_keys = g_keystore.loadFromKyamlSrc(cfg_arena.allocator(), src) catch |e| blk: {
                std.debug.print("[aerie] keystore: KYAML parse error in {s} ({}) — env keys only\n", .{ path, e });
                break :blk 0;
            };
        } else |e| {
            std.debug.print("[aerie] keystore: cannot read {s} ({}) — env keys only\n", .{ path, e });
        }
    }
    if (g_cfg.auth_mode == .deny) {
        std.debug.print("[aerie] keystore: {d} key(s) loaded (env: {d}, kyaml: {d}) — deny-by-default\n", .{ g_keystore.count, env_keys, yaml_keys });
    }
    g_ready = true;

    // Single-port setup: create → register V2 handler → start.
    gnosis_http_handle = c.uapi_gnosis_create(g_cfg.port);
    if (gnosis_http_handle == 0) {
        std.debug.print("[aerie] FATAL: gnosis pool slot unavailable for port {d}\n", .{g_cfg.port});
        return error.GnosisCreateFailed;
    }
    defer releaseGnosisHandle(&gnosis_http_handle);

    const set_rc = c.uapi_gnosis_set_handler_v2(gnosis_http_handle, &aerieHandlerV2);
    if (set_rc != c.UAPI_OK) {
        std.debug.print("[aerie] FATAL: uapi_gnosis_set_handler_v2 failed (result={d})\n", .{set_rc});
        return error.GnosisSetHandlerFailed;
    }

    const start_rc = c.uapi_gnosis_start(gnosis_http_handle);
    if (start_rc != c.UAPI_OK) {
        std.debug.print("[aerie] FATAL: uapi_gnosis_start failed (result={d})\n", .{start_rc});
        return error.GnosisStartFailed;
    }

    std.debug.print("[aerie] Listening on :{d} — REST /api/v1/* | GraphQL /graphql | gRPC-JSON /grpc/*\n", .{g_cfg.port});

    // Block main thread until the server stops.
    while (c.uapi_gnosis_state(gnosis_http_handle) == c.UAPI_SERVER_LISTENING) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}

fn printBanner(cfg: *const config.Config) void {
    std.debug.print(
        \\
        \\+----------------------------------------------------------+
        \\|   AERIE GATEWAY — Zig (single-port, MPL-2.0)             |
        \\+----------------------------------------------------------+
        \\|  Port            : {d:<5}                                     |
        \\|  REST            : /api/v1/*   {s}                       |
        \\|  GraphQL         : /graphql    {s}                       |
        \\|  gRPC-JSON       : /grpc/*     {s}                       |
        \\|  Auth mode       : {s}   ({d} keys loaded)          |
        \\+----------------------------------------------------------+
        \\|  Server pool     : uapi_gnosis_*   (in-repo zig_api)     |
        \\|  Connector pool  : uapi_connector_* (in-repo zig_api)    |
        \\|  Proof mode      : light (SHA-256)                       |
        \\|  Policy gate     : Phase 2 (keystore, deny-by-default)    |
        \\+----------------------------------------------------------+
        \\
    , .{
        cfg.port,
        if (cfg.rest_enabled) "ENABLED " else "disabled",
        if (cfg.graphql_enabled) "ENABLED " else "disabled",
        if (cfg.grpc_enabled) "ENABLED " else "disabled",
        @tagName(cfg.auth_mode),
        g_keystore.count,
    });
}
