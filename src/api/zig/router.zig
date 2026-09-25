// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// router.zig — the single route table and the dispatch pipeline.
//
// METAICONIC: the weave is data. This table is the one place that
// declares paths, verbs, policy modules and resolvers; dispatch, verb
// governance and the policy gate all consume it. The old design kept
// three parallel route tables (a startsWith chain, moduleFromPath, and
// verb_governance.RULES) in sync by hand; this is the table that
// replaces them.
//
// REFLECTIVE: /api/v1/health (and, in Phase 2, /api/v1/meta) render the
// table itself — routes, verbs, modules — rather than a hand-copied
// description. The description cannot drift from the behaviour because
// it IS the behaviour.

const std = @import("std");
const t = @import("types.zig");
const ctx = @import("ctx.zig");
const res = @import("resolvers.zig");
const pol = @import("policy.zig");
const config = @import("config.zig");
const prf = @import("proof.zig");
const vg = @import("verb_governance.zig");
const respond = @import("respond.zig");
const errors = @import("errors.zig");
const aspects = @import("aspects.zig");

pub const Resolver = *const fn (*ctx.Ctx) void;

pub const Route = struct {
    path: []const u8,
    verbs: []const []const u8,
    module: []const u8,
    resolver: Resolver,
    /// Public routes bypass the deny-by-default gate (health, meta).
    /// They are still policy-evaluated and audited.
    public: bool = false,
    /// The aspects this resolution runs (single source: the consts in
    /// resolvers.zig; rendered by /api/v1/meta).
    aspects: []const aspects.Aspect = &.{},
};

/// THE table. Longest-prefix wins; boundary-guarded (a route matches
/// only at end-of-path or at a '/'), so /api/v1/telemetryX matches
/// nothing. gRPC is dispatched by the /grpc/ prefix (method names are
/// dynamic) and is not table-mapped.
pub const routes = [_]Route{
    .{ .path = "/api/v1/health", .verbs = &.{ "GET", "OPTIONS" }, .module = "health", .resolver = healthResolver, .public = true },
    .{ .path = "/api/v1/meta", .verbs = &.{ "GET", "OPTIONS" }, .module = "meta", .resolver = metaResolver, .public = true },
    .{ .path = "/api/v1/telemetry", .verbs = &.{ "GET", "OPTIONS" }, .module = "telemetry", .resolver = telemetryResolver, .aspects = &res.telemetry_aspects },
    .{ .path = "/api/v1/routes", .verbs = &.{ "GET", "OPTIONS" }, .module = "routes", .resolver = routesResolver, .aspects = &res.routes_aspects },
    .{ .path = "/api/v1/audit/temporal", .verbs = &.{ "GET", "OPTIONS" }, .module = "temporal_audit", .resolver = temporalResolver, .aspects = &res.temporal_aspects },
    .{ .path = "/api/v1/audit", .verbs = &.{ "GET", "OPTIONS" }, .module = "audit", .resolver = auditResolver, .aspects = &res.audit_aspects },
    .{ .path = "/api/v1/smokeping", .verbs = &.{ "GET", "OPTIONS" }, .module = "smokeping", .resolver = smokepingResolver, .aspects = &res.smokeping_aspects },
    .{ .path = "/graphql", .verbs = &.{ "GET", "POST", "OPTIONS" }, .module = "graphql", .resolver = graphqlResolver },
};

/// Boundary-guarded longest-prefix match.
pub fn find(path: []const u8) ?*const Route {
    var best: ?*const Route = null;
    var best_len: usize = 0;
    for (&routes) |*route| {
        if (!std.mem.startsWith(u8, path, route.path)) continue;
        const boundary = path.len == route.path.len or path[route.path.len] == '/';
        if (!boundary) continue;
        if (route.path.len > best_len) {
            best = route;
            best_len = route.path.len;
        }
    }
    return best;
}

/// Verb check against the table.
pub fn verbAllowed(route: *const Route, method: []const u8) bool {
    for (route.verbs) |v| {
        if (std.ascii.eqlIgnoreCase(method, v)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Dispatch — the ordered pipeline (aspects grow around this spine)
// ---------------------------------------------------------------------------

pub fn dispatch(c: *ctx.Ctx) void {
    // CORS preflight.
    if (std.ascii.eqlIgnoreCase(c.method, "OPTIONS")) {
        c.status = 204;
        c.resp_body = "";
        return;
    }

    // Protocol enablement (health is always available).
    if (std.mem.startsWith(u8, c.path, "/graphql") and !c.cfg.graphql_enabled) {
        respond.respondError(c, 404, "GraphQL disabled (hint: set ENABLE_GRAPHQL=true)");
        return;
    }
    if (std.mem.startsWith(u8, c.path, "/api/v1/") and
        !std.mem.startsWith(u8, c.path, "/api/v1/health") and
        !c.cfg.rest_enabled)
    {
        respond.respondError(c, 404, "REST disabled (hint: set ENABLE_REST=true)");
        return;
    }
    if (std.mem.startsWith(u8, c.path, "/grpc/") and !c.cfg.grpc_enabled) {
        respond.respondError(c, 404, "gRPC disabled (hint: set ENABLE_GRPC=true)");
        return;
    }

    // gRPC-JSON: dynamic method names dispatch by prefix.
    if (std.mem.startsWith(u8, c.path, "/grpc/")) {
        const method_name = c.path["/grpc/".len..];
        const grpc_method = if (method_name.len > 0) method_name else c.jsonStrField("method");
        c.policy = pol.evaluatePolicy(c.keystore, c.cfg.auth_mode, c.header("x-api-key"), grpc_method);
        if (!c.policy.allowed) {
            enforceAuth(c);
            return;
        }
        grpcDispatch(c, grpc_method);
        return;
    }

    // Table routing.
    const route = find(c.path) orelse {
        // Unknown routes stay stealth-404 — the policy decision is still
        // evaluated and audited, but never leaks route existence.
        c.policy = pol.evaluatePolicy(c.keystore, c.cfg.auth_mode, c.header("x-api-key"), "unknown");
        res.logAudit(c.redis, c.policy);
        respond.respond(c, 404, notFoundJson(c));
        return;
    };
    c.route = route;

    // Verb governance (stealth mode: 404 + timing jitter on denial).
    if (!verbAllowed(route, c.method)) {
        vg.stealthDelay();
        c.policy = pol.evaluatePolicy(c.keystore, c.cfg.auth_mode, "", route.module);
        res.logAudit(c.redis, c.policy);
        respond.respondError(c, 404, "not found");
        return;
    }

    // Policy gate — deny-by-default with keystore entitlements; public
    // routes (health, meta) are exempt but still evaluated and audited.
    c.policy = pol.evaluatePolicy(c.keystore, c.cfg.auth_mode, c.header("x-api-key"), route.module);
    if (!route.public and !c.policy.allowed) {
        enforceAuth(c);
        return;
    }
    if (route.public and !c.policy.allowed) {
        // Public route, denied key: serve, but audit the denial.
        res.logAudit(c.redis, c.policy);
    }

    route.resolver(c);
}

/// Respond to a policy denial: 401 when the key is absent/unknown,
/// 403 when the key is valid but unentitled. The denial is audited.
fn enforceAuth(c: *ctx.Ctx) void {
    res.logAudit(c.redis, c.policy);
    const code: u16 = if (c.policy.access_level == .authenticated) 403 else 401;
    var rb: [128]u8 = undefined;
    const reason = std.fmt.bufPrint(&rb, "{s}", .{std.mem.sliceTo(&c.policy.reason, 0)})
        catch "not authorized";
    respond.respondError(c, code, reason);
}

// ---------------------------------------------------------------------------
// Route adapters (the bridge to the existing resolvers; Phase 2 folds
// the cache/envelope/audit decorators in here, once per concern)
// ---------------------------------------------------------------------------

fn healthResolver(c: *ctx.Ctx) void {
    respond.respond(c, 200, healthJson(c));
}

fn metaResolver(c: *ctx.Ctx) void {
    respond.respond(c, 200, metaJson(c));
}

fn telemetryResolver(c: *ctx.Ctx) void {
    res.resolveTelemetry(c);
}

fn routesResolver(c: *ctx.Ctx) void {
    const target = c.param("target");
    if (target.len == 0) {
        respond.respondError(c, 400, "missing required parameter: target (REST: ?target=…; gRPC body field target)");
        return;
    }
    res.resolveRoutes(c, target);
}

fn temporalResolver(c: *ctx.Ctx) void {
    const mode = c.param("mode");
    if (mode.len == 0) {
        respond.respondError(c, 400, "missing required parameter: mode (as_of, between, history)");
        return;
    }
    const params = t.TemporalParams{
        .time = c.param("time"),
        .start = c.param("start"),
        .end = c.param("end"),
        .event_id = c.param("event_id"),
        .limit = std.fmt.parseInt(u32, c.param("limit"), 10) catch 50,
    };
    res.resolveTemporal(c, mode, params);
}

fn auditResolver(c: *ctx.Ctx) void {
    const limit = std.fmt.parseInt(u32, c.param("limit"), 10) catch 50;
    res.resolveAudit(c, limit);
}

fn smokepingResolver(c: *ctx.Ctx) void {
    const target = c.param("target");
    if (target.len == 0) {
        respond.respondError(c, 400, "missing required parameter: target (REST: ?target=…; gRPC body field target)");
        return;
    }
    res.resolveSmokeping(c, target);
}

fn graphqlResolver(c: *ctx.Ctx) void {
    // GraphQL reports errors in-band (HTTP 200 with an errors array),
    // per its transport conventions.
    if (!std.ascii.eqlIgnoreCase(c.method, "POST")) {
        respond.respond(c, 200, "{\"errors\":[{\"message\":\"GraphQL endpoint requires POST method\"}]}");
        return;
    }
    const query = c.jsonStrField("query");
    if (query.len == 0) {
        respond.respond(c, 200, "{\"errors\":[{\"message\":\"Missing query field in request body\"}]}");
        return;
    }
    res.resolveGraphqlQuery(c, query);
}

/// gRPC-JSON dispatch (method name from path or body).
fn grpcDispatch(c: *ctx.Ctx, method_name: []const u8) void {
    if (std.mem.eql(u8, method_name, "GetTelemetrySnapshot")) {
        res.resolveTelemetry(c);
        return;
    }
    if (std.mem.eql(u8, method_name, "GetRouteForensicsSnapshot")) {
        const target = c.jsonStrField("target");
        if (target.len == 0) {
            respond.respondError(c, 400, "target field required");
            return;
        }
        res.resolveRoutes(c, target);
        return;
    }
    if (std.mem.eql(u8, method_name, "GetAuditSnapshot")) {
        res.resolveAudit(c, c.jsonIntField("limit") orelse 50);
        return;
    }
    if (std.mem.eql(u8, method_name, "GetSmokePingSnapshot")) {
        const target = c.jsonStrField("target");
        if (target.len == 0) {
            respond.respondError(c, 400, "target field required");
            return;
        }
        res.resolveSmokeping(c, target);
        return;
    }
    if (std.mem.eql(u8, method_name, "GetTemporalAuditSnapshot")) {
        const mode = c.jsonStrField("mode");
        if (mode.len == 0) {
            respond.respondError(c, 400, "mode field required (as_of, between, history)");
            return;
        }
        const params = t.TemporalParams{
            .time = c.jsonStrField("time"),
            .start = c.jsonStrField("start"),
            .end = c.jsonStrField("end"),
            .event_id = c.jsonStrField("event_id"),
            .limit = c.jsonIntField("limit") orelse 50,
        };
        res.resolveTemporal(c, mode, params);
        return;
    }
    var eb: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&eb,
        "{{\"error\":\"Unknown method: {s}\"," ++
            "\"available\":[\"GetTelemetrySnapshot\",\"GetRouteForensicsSnapshot\"," ++
            "\"GetAuditSnapshot\",\"GetSmokePingSnapshot\",\"GetTemporalAuditSnapshot\"]}}",
        .{method_name},
    ) catch "{\"error\":\"unknown method\"}";
    respond.respond(c, 404, c.copyToBody(body, "{\"error\":\"unknown method\"}"));
}

// ---------------------------------------------------------------------------
// Reflective renderings (health + not-found describe the live table)
// ---------------------------------------------------------------------------

const GATEWAY_VERSION = "0.4.0";

/// Health JSON — includes the live gnosis pool state handed in via Ctx.
pub fn healthJson(c: *ctx.Ctx) []const u8 {
    var ts_buf: [32]u8 = undefined;
    prf.formatRfc3339(&ts_buf);
    const ts = std.mem.sliceTo(&ts_buf, 0);
    const cfg = c.cfg;
    var active: u8 = 0;
    if (cfg.rest_enabled) active += 1;
    if (cfg.graphql_enabled) active += 1;
    if (cfg.grpc_enabled) active += 1;
    var bound: u8 = 0;
    if (cfg.rest_enabled or cfg.graphql_enabled) bound += 1;
    if (cfg.grpc_enabled) bound += 1;
    return std.fmt.bufPrint(c.out_buf,
        "{{\"status\":\"healthy\",\"service\":\"aerie-gateway\",\"version\":\"{s}\"," ++
            "\"timestamp\":\"{s}\",\"protocols\":{{\"rest\":{s},\"graphql\":{s},\"grpc\":{s}}}," ++
            "\"active_protocols\":{d},\"bound_ports\":{d}," ++
            "\"verb_governance\":true,\"stealth_mode\":true,\"proof_mode\":\"light\"," ++
            "\"policy_phase\":2,\"auth\":\"{s}\",\"pool\":{{\"slot_state\":{d}}}}}",
        .{
            GATEWAY_VERSION,                                                          ts,
            if (cfg.rest_enabled) "true" else "false",                                if (cfg.graphql_enabled) "true" else "false",
            if (cfg.grpc_enabled) "true" else "false",                                active,
            bound,                                                                    @tagName(cfg.auth_mode),
            c.pool_state,
        },
    ) catch "{\"status\":\"healthy\"}";
}

/// /api/v1/meta — the gateway describes itself from the same tables the
/// dispatcher uses: routes, verbs, modules, aspects, auth posture,
/// versions. The description cannot drift from the behaviour because it
/// IS the behaviour. No key material, no URLs, no secrets.
pub fn metaJson(c: *ctx.Ctx) []const u8 {
    var fbs = std.io.fixedBufferStream(c.out_buf);
    const w = fbs.writer();
    w.print("{{\"service\":\"aerie-gateway\",\"version\":\"{s}\",\"policy_phase\":2," ++
        "\"auth\":\"{s}\",\"aspects\":[\"cache\",\"enveloped\",\"audited\",\"dual_audited\"]," ++
        "\"forensics\":\"FS-0 (untrusted search, trusted checking)\"," ++
        "\"routes\":[", .{ GATEWAY_VERSION, @tagName(c.cfg.auth_mode) }) catch {};
    for (&routes, 0..) |*route, i| {
        if (i > 0) w.writeByte(',') catch {};
        w.print("{{\"path\":\"{s}\",\"verbs\":[", .{route.path}) catch {};
        for (route.verbs, 0..) |v, j| {
            if (j > 0) w.writeByte(',') catch {};
            w.print("\"{s}\"", .{v}) catch {};
        }
        w.writeAll("],\"module\":\"") catch {};
        w.writeAll(route.module) catch {};
        w.writeByte('"') catch {};
        if (route.public) w.writeAll(",\"public\":true") catch {};
        if (route.aspects.len > 0) {
            w.writeAll(",\"aspects\":[") catch {};
            var abuf: [32]u8 = undefined;
            for (route.aspects, 0..) |asp, j| {
                if (j > 0) w.writeByte(',') catch {};
                w.writeByte('"') catch {};
                w.writeAll(aspects.describe(asp, &abuf)) catch {};
                w.writeByte('"') catch {};
            }
            w.writeAll("]") catch {};
        }
        w.writeAll("}") catch {};
    }
    w.writeAll("]}") catch {};
    return fbs.getWritten();
}

/// Not-found JSON — lists only enabled endpoints, derived from the table.
pub fn notFoundJson(c: *ctx.Ctx) []const u8 {
    var fbs = std.io.fixedBufferStream(c.out_buf);
    const w = fbs.writer();
    w.writeAll("{\"error\":\"Not found\",\"available_endpoints\":[") catch {};
    var first = true;
    for (&routes) |*route| {
        if (std.mem.eql(u8, route.module, "graphql") and !c.cfg.graphql_enabled) continue;
        if (std.mem.startsWith(u8, route.path, "/api/v1/") and
            !std.mem.eql(u8, route.path, "/api/v1/health") and !c.cfg.rest_enabled) continue;
        if (!first) w.writeByte(',') catch {};
        w.writeAll("\"") catch {};
        w.writeAll(route.path) catch {};
        w.writeAll("\"") catch {};
        first = false;
    }
    w.writeAll("]}") catch {};
    return fbs.getWritten();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "router: boundary-guarded longest-prefix match" {
    try std.testing.expectEqualStrings("temporal_audit", find("/api/v1/audit/temporal").?.module);
    try std.testing.expectEqualStrings("audit", find("/api/v1/audit").?.module);
    try std.testing.expectEqualStrings("telemetry", find("/api/v1/telemetry").?.module);
    // boundary guard: telemetryX matches nothing
    try std.testing.expect(find("/api/v1/telemetryX") == null);
    // sub-resource falls through to the parent route
    try std.testing.expectEqualStrings("audit", find("/api/v1/audit/other").?.module);
    try std.testing.expect(find("/nope") == null);
}

test "router: meta renders the live table (self-description)" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var out: [4096]u8 = undefined;
    const cfg = config.Config{};
    var c = ctx.Ctx{
        .arena = arena_inst.allocator(),
        .method = "GET",
        .path = "/api/v1/meta",
        .query = "",
        .body = "",
        .header_names = null,
        .header_values = null,
        .header_count = 0,
        .cfg = &cfg,
        .redis = undefined,
        .verisim = undefined,
        .out_buf = &out,
    };
    const meta = metaJson(&c);
    // telemetry row carries its aspects; meta itself is public
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"aspects\":[\"cache:30s\",\"enveloped\",\"audited\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"module\":\"meta\",\"public\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"auth\":\"deny\"") != null);
}

test "router: verbs enforced per route" {
    const telemetry = find("/api/v1/telemetry").?;
    try std.testing.expect(verbAllowed(telemetry, "GET"));
    try std.testing.expect(!verbAllowed(telemetry, "POST"));
    try std.testing.expect(!verbAllowed(telemetry, "DELETE"));
    const graphql = find("/graphql").?;
    try std.testing.expect(verbAllowed(graphql, "POST"));
    try std.testing.expect(verbAllowed(graphql, "get")); // case-insensitive
}
