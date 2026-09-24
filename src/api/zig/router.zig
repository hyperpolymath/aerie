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
const prf = @import("proof.zig");
const vg = @import("verb_governance.zig");
const respond = @import("respond.zig");
const errors = @import("errors.zig");

pub const Resolver = *const fn (*ctx.Ctx) void;

pub const Route = struct {
    path: []const u8,
    verbs: []const []const u8,
    module: []const u8,
    resolver: Resolver,
};

/// THE table. Longest-prefix wins; boundary-guarded (a route matches
/// only at end-of-path or at a '/'), so /api/v1/telemetryX matches
/// nothing. gRPC is dispatched by the /grpc/ prefix (method names are
/// dynamic) and is not table-mapped.
pub const routes = [_]Route{
    .{ .path = "/api/v1/health", .verbs = &.{ "GET", "OPTIONS" }, .module = "health", .resolver = healthResolver },
    .{ .path = "/api/v1/telemetry", .verbs = &.{ "GET", "OPTIONS" }, .module = "telemetry", .resolver = telemetryResolver },
    .{ .path = "/api/v1/routes", .verbs = &.{ "GET", "OPTIONS" }, .module = "routes", .resolver = routesResolver },
    .{ .path = "/api/v1/audit/temporal", .verbs = &.{ "GET", "OPTIONS" }, .module = "temporal_audit", .resolver = temporalResolver },
    .{ .path = "/api/v1/audit", .verbs = &.{ "GET", "OPTIONS" }, .module = "audit", .resolver = auditResolver },
    .{ .path = "/api/v1/smokeping", .verbs = &.{ "GET", "OPTIONS" }, .module = "smokeping", .resolver = smokepingResolver },
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
        c.policy = pol.evaluatePolicy(c.header("x-api-key"), grpc_method);
        grpcDispatch(c, grpc_method);
        return;
    }

    // Table routing.
    const route = find(c.path) orelse {
        c.policy = pol.evaluatePolicy(c.header("x-api-key"), "unknown");
        respond.respond(c, 404, notFoundJson(c));
        return;
    };
    c.route = route;

    // Verb governance (stealth mode: 404 + timing jitter on denial).
    if (!verbAllowed(route, c.method)) {
        vg.stealthDelay();
        c.policy = pol.evaluatePolicy("", route.module);
        respond.respondError(c, vg.denialStatusCode(.{
            .allowed = false, .matched = true, .stealth = true,
            .rule_name = undefined, .rule_len = 0, .verb = undefined, .verb_len = 0,
        }), "not found");
        return;
    }

    // Policy gate — with the REAL API key at last (V2 headers).
    c.policy = pol.evaluatePolicy(c.header("x-api-key"), route.module);

    route.resolver(c);
}

// ---------------------------------------------------------------------------
// Route adapters (the bridge to the existing resolvers; Phase 2 folds
// the cache/envelope/audit decorators in here, once per concern)
// ---------------------------------------------------------------------------

fn healthResolver(c: *ctx.Ctx) void {
    respond.respond(c, 200, healthJson(c));
}

fn telemetryResolver(c: *ctx.Ctx) void {
    respond.respond(c, 200, res.resolveTelemetry(c.redis, c.policy, c.out_buf, c.arena));
}

fn routesResolver(c: *ctx.Ctx) void {
    const target = c.queryParam("target");
    if (target.len == 0) {
        respond.respondError(c, 400, "missing required query parameter: target (usage: /api/v1/routes?target=<ip_or_hostname>)");
        return;
    }
    respond.respond(c, 200, res.resolveRouteForensics(target, c.redis, c.policy, c.out_buf, c.arena));
}

fn temporalResolver(c: *ctx.Ctx) void {
    const mode = c.queryParam("mode");
    if (mode.len == 0) {
        respond.respondError(c, 400, "missing required query parameter: mode (usage: /api/v1/audit/temporal?mode=as_of&time=...; available: as_of, between, history)");
        return;
    }
    const params = res.TemporalParams{
        .time = c.queryParam("time"),
        .start = c.queryParam("start"),
        .end = c.queryParam("end"),
        .event_id = c.queryParam("event_id"),
        .limit = std.fmt.parseInt(u32, c.queryParam("limit"), 10) catch 50,
    };
    respond.respond(c, 200, res.resolveTemporalAudit(mode, params, c.redis, c.verisim, c.policy, c.out_buf, c.arena));
}

fn auditResolver(c: *ctx.Ctx) void {
    const limit = std.fmt.parseInt(u32, c.queryParam("limit"), 10) catch 50;
    respond.respond(c, 200, res.resolveAudit(limit, c.redis, c.policy, c.out_buf, c.arena));
}

fn smokepingResolver(c: *ctx.Ctx) void {
    const target = c.queryParam("target");
    if (target.len == 0) {
        respond.respondError(c, 400, "missing required query parameter: target (usage: /api/v1/smokeping?target=<hostname_or_ip>)");
        return;
    }
    respond.respond(c, 200, res.resolveSmokeping(target, c.redis, c.policy, c.out_buf, c.arena));
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
    respond.respond(c, 200, res.resolveGraphqlQuery(query, c.redis, c.verisim, c.policy, c.out_buf, c.arena));
}

/// gRPC-JSON dispatch (method name from path or body).
fn grpcDispatch(c: *ctx.Ctx, method_name: []const u8) void {
    if (std.mem.eql(u8, method_name, "GetTelemetrySnapshot")) {
        respond.respond(c, 200, res.resolveTelemetry(c.redis, c.policy, c.out_buf, c.arena));
        return;
    }
    if (std.mem.eql(u8, method_name, "GetRouteForensicsSnapshot")) {
        const target = c.jsonStrField("target");
        if (target.len == 0) {
            respond.respondError(c, 400, "target field required");
            return;
        }
        respond.respond(c, 200, res.resolveRouteForensics(target, c.redis, c.policy, c.out_buf, c.arena));
        return;
    }
    if (std.mem.eql(u8, method_name, "GetAuditSnapshot")) {
        const limit = c.jsonIntField("limit") orelse @as(u32, 50);
        respond.respond(c, 200, res.resolveAudit(limit, c.redis, c.policy, c.out_buf, c.arena));
        return;
    }
    if (std.mem.eql(u8, method_name, "GetSmokePingSnapshot")) {
        const target = c.jsonStrField("target");
        if (target.len == 0) {
            respond.respondError(c, 400, "target field required");
            return;
        }
        respond.respond(c, 200, res.resolveSmokeping(target, c.redis, c.policy, c.out_buf, c.arena));
        return;
    }
    if (std.mem.eql(u8, method_name, "GetTemporalAuditSnapshot")) {
        const mode = c.jsonStrField("mode");
        if (mode.len == 0) {
            respond.respondError(c, 400, "mode field required (as_of, between, history)");
            return;
        }
        const params = res.TemporalParams{
            .time = c.jsonStrField("time"),
            .start = c.jsonStrField("start"),
            .end = c.jsonStrField("end"),
            .event_id = c.jsonStrField("event_id"),
            .limit = c.jsonIntField("limit") orelse 50,
        };
        respond.respond(c, 200, res.resolveTemporalAudit(mode, params, c.redis, c.verisim, c.policy, c.out_buf, c.arena));
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

const GATEWAY_VERSION = "0.3.0";

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
            "\"policy_phase\":2,\"pool\":{{\"slot_state\":{d}}}}}",
        .{
            GATEWAY_VERSION,                                                          ts,
            if (cfg.rest_enabled) "true" else "false",                                if (cfg.graphql_enabled) "true" else "false",
            if (cfg.grpc_enabled) "true" else "false",                                active,
            bound,                                                                     c.pool_state,
        },
    ) catch "{\"status\":\"healthy\"}";
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

test "router: verbs enforced per route" {
    const telemetry = find("/api/v1/telemetry").?;
    try std.testing.expect(verbAllowed(telemetry, "GET"));
    try std.testing.expect(!verbAllowed(telemetry, "POST"));
    try std.testing.expect(!verbAllowed(telemetry, "DELETE"));
    const graphql = find("/graphql").?;
    try std.testing.expect(verbAllowed(graphql, "POST"));
    try std.testing.expect(verbAllowed(graphql, "get")); // case-insensitive
}
