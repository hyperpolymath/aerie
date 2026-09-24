// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// config.zig — typed configuration, loaded once at startup.
//
// Precedence (12-factor): defaults < KYAML file (AERIE_CONFIG) < env.
// KYAML per estate rule Y-3 (standards/3-practice/YAML-POLICY.adoc,
// parser: kyaml.zig). Unknown keys are ERRORS, not silently ignored —
// a typo in a config file must never quietly take the default.
//
// This is the ONLY module that reads the environment (getenv appears
// nowhere else in the gateway; the probe clients keep their legacy
// env reads until the Phase-3 transport unification).

const std = @import("std");
const kyaml = @import("kyaml.zig");

pub const AuthMode = enum { open, deny };

pub const Config = struct {
    port: u16 = 4000,
    rest_enabled: bool = true,
    graphql_enabled: bool = true,
    grpc_enabled: bool = true,

    redis_url: []const u8 = "redis://redis:6379",
    librespeed_url: []const u8 = "http://librespeed:80",
    hyperglass_url: []const u8 = "http://hyperglass:80",
    smokeping_url: []const u8 = "http://smokeping:80",
    verisim_url: []const u8 = "http://verisim:8084",

    /// Phase 2 flips the default to .deny when the keystore lands;
    /// until then .open preserves the Phase-1 permissive behaviour —
    /// honestly, not silently.
    auth_mode: AuthMode = .open,

    /// Environment accessor, injectable for tests.
    pub const Env = *const fn (name: []const u8) ?[]const u8;

    fn realEnv(name: []const u8) ?[]const u8 {
        return std.posix.getenv(name);
    }

    /// Load with precedence: defaults < KYAML file (AERIE_CONFIG) < env.
    /// All returned strings are duplicated into `arena` (stable for the
    /// process lifetime; no getenv-lifetime hazards).
    pub fn load(arena: std.mem.Allocator) Config {
        return loadWithEnv(arena, realEnv);
    }

    pub fn loadWithEnv(arena: std.mem.Allocator, env: Env) Config {
        var cfg = Config{};

        if (env("AERIE_CONFIG")) |path| {
            const src = std.fs.cwd().readFileAlloc(arena, path, 1 << 20) catch |e| {
                std.debug.print("[aerie] config: cannot read {s} ({}) — using defaults+env\n", .{ path, e });
                return applyEnv(arena, cfg, env);
            };
            cfg.applyKyaml(arena, src) catch |e| {
                std.debug.print("[aerie] config: KYAML parse error in {s} ({}) — using defaults+env\n", .{ path, e });
                return applyEnv(arena, cfg, env);
            };
        }

        return applyEnv(arena, cfg, env);
    }

    /// Apply a KYAML document. Unknown keys are errors (typo safety).
    pub fn applyKyaml(self: *Config, arena: std.mem.Allocator, src: []const u8) kyaml.Error!void {
        const doc = try kyaml.parse(arena, src);
        const m = switch (doc) {
            .map => |m| m,
            else => return kyaml.Error.EmptyDocument,
        };
        for (m.entries) |e| {
            if (std.mem.eql(u8, e.key, "port")) {
                self.port = @intCast(e.value.asInt() orelse return kyaml.Error.UnquotedScalar);
            } else if (std.mem.eql(u8, e.key, "rest")) {
                self.rest_enabled = e.value.asBool() orelse return kyaml.Error.UnquotedScalar;
            } else if (std.mem.eql(u8, e.key, "graphql")) {
                self.graphql_enabled = e.value.asBool() orelse return kyaml.Error.UnquotedScalar;
            } else if (std.mem.eql(u8, e.key, "grpc")) {
                self.grpc_enabled = e.value.asBool() orelse return kyaml.Error.UnquotedScalar;
            } else if (std.mem.eql(u8, e.key, "redis_url")) {
                self.redis_url = try arena.dupe(u8, e.value.asString() orelse return kyaml.Error.UnquotedScalar);
            } else if (std.mem.eql(u8, e.key, "librespeed_url")) {
                self.librespeed_url = try arena.dupe(u8, e.value.asString() orelse return kyaml.Error.UnquotedScalar);
            } else if (std.mem.eql(u8, e.key, "hyperglass_url")) {
                self.hyperglass_url = try arena.dupe(u8, e.value.asString() orelse return kyaml.Error.UnquotedScalar);
            } else if (std.mem.eql(u8, e.key, "smokeping_url")) {
                self.smokeping_url = try arena.dupe(u8, e.value.asString() orelse return kyaml.Error.UnquotedScalar);
            } else if (std.mem.eql(u8, e.key, "verisim_url")) {
                self.verisim_url = try arena.dupe(u8, e.value.asString() orelse return kyaml.Error.UnquotedScalar);
            } else if (std.mem.eql(u8, e.key, "auth")) {
                const v = e.value.asString() orelse return kyaml.Error.UnquotedScalar;
                if (std.mem.eql(u8, v, "open")) {
                    self.auth_mode = .open;
                } else if (std.mem.eql(u8, v, "deny")) {
                    self.auth_mode = .deny;
                } else {
                    return kyaml.Error.TrailingJunk; // unknown auth mode value
                }
            } else {
                return kyaml.Error.BadKey; // unknown key: typo safety
            }
        }
    }

    fn applyEnv(arena: std.mem.Allocator, cfg_in: Config, env: Env) Config {
        var cfg = cfg_in;
        if (env("PORT")) |v| {
            cfg.port = std.fmt.parseInt(u16, v, 10) catch cfg.port;
        }
        if (env("ENABLE_REST")) |v| cfg.rest_enabled = envBool(v, cfg.rest_enabled);
        if (env("ENABLE_GRAPHQL")) |v| cfg.graphql_enabled = envBool(v, cfg.graphql_enabled);
        if (env("ENABLE_GRPC")) |v| cfg.grpc_enabled = envBool(v, cfg.grpc_enabled);
        if (env("REDIS_URL")) |v| cfg.redis_url = arena.dupe(u8, v) catch cfg.redis_url;
        if (env("LIBRESPEED_URL")) |v| cfg.librespeed_url = arena.dupe(u8, v) catch cfg.librespeed_url;
        if (env("HYPERGLASS_URL")) |v| cfg.hyperglass_url = arena.dupe(u8, v) catch cfg.hyperglass_url;
        if (env("SMOKEPING_URL")) |v| cfg.smokeping_url = arena.dupe(u8, v) catch cfg.smokeping_url;
        if (env("VERISIMDB_URL")) |v| cfg.verisim_url = arena.dupe(u8, v) catch cfg.verisim_url;
        if (env("AERIE_AUTH_MODE")) |v| {
            if (std.mem.eql(u8, v, "deny")) cfg.auth_mode = .deny;
            if (std.mem.eql(u8, v, "open")) cfg.auth_mode = .open;
        }
        return cfg;
    }

    /// "false"/"0"/"no" (case-insensitive) → false; anything else → default.
    fn envBool(v: []const u8, default: bool) bool {
        if (v.len == 0) return default;
        return !(std.ascii.eqlIgnoreCase(v, "false") or
            std.ascii.eqlIgnoreCase(v, "0") or
            std.ascii.eqlIgnoreCase(v, "no"));
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = struct {
    vars: []const [2][]const u8,
    fn get(self: *const TestEnv, name: []const u8) ?[]const u8 {
        for (self.vars) |kv| {
            if (std.mem.eql(u8, kv[0], name)) return kv[1];
        }
        return null;
    }
};

fn testEnvPtr(entries: []const [2][]const u8) Config.Env {
    const S = struct {
        var vars: []const [2][]const u8 = &.{};
        fn get(name: []const u8) ?[]const u8 {
            for (vars) |kv| {
                if (std.mem.eql(u8, kv[0], name)) return kv[1];
            }
            return null;
        }
    };
    S.vars = entries;
    return S.get;
}

test "config: defaults match the compose topology" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = Config.loadWithEnv(arena.allocator(), testEnvPtr(&.{}));
    try std.testing.expectEqual(@as(u16, 4000), cfg.port);
    try std.testing.expect(cfg.rest_enabled and cfg.graphql_enabled and cfg.grpc_enabled);
    try std.testing.expectEqualStrings("http://librespeed:80", cfg.librespeed_url);
    try std.testing.expectEqual(AuthMode.open, cfg.auth_mode);
}

test "config: env overrides defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = Config.loadWithEnv(arena.allocator(), testEnvPtr(&.{
        .{ "PORT", "4321" },
        .{ "ENABLE_GRPC", "false" },
        .{ "LIBRESPEED_URL", "http://probe:9999" },
    }));
    try std.testing.expectEqual(@as(u16, 4321), cfg.port);
    try std.testing.expect(!cfg.grpc_enabled);
    try std.testing.expectEqualStrings("http://probe:9999", cfg.librespeed_url);
}

test "config: kyaml overlay and typo rejection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = Config{};
    try cfg.applyKyaml(arena.allocator(),
        "---\nport: 5000\nrest: false\nauth: \"deny\"\n");
    try std.testing.expectEqual(@as(u16, 5000), cfg.port);
    try std.testing.expect(!cfg.rest_enabled);
    try std.testing.expectEqual(AuthMode.deny, cfg.auth_mode);

    // unknown key is an error, not a silent default
    var bad = Config{};
    try std.testing.expectError(kyaml.Error.BadKey, bad.applyKyaml(arena.allocator(), "---\nprot: 1\n"));
}
