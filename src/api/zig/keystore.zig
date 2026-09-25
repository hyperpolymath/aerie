// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// keystore.zig — API keys, entitlements and the deny-by-default gate
// (Phase 2 of the aspect weave).
//
// Keys are DATA, not code: loaded from AERIE_API_KEYS (semicolon-
// separated specs) and/or the KYAML `api_keys:` flow list. A spec is
//   key                      — name defaults to the key, all modules
//   key:name                 — named principal, all modules
//   key:name:mod1,mod2       — named principal, module entitlements
// ("*" in the module list means every module.)
//
// Authorisation compares against every entry (no early exit) with a
// constant-time equality — key presence is not a timing side channel.
// Keys never appear in logs, decisions or meta output except redacted.

const std = @import("std");
const kyaml = @import("kyaml.zig");

pub const MAX_KEYS: usize = 32;
pub const MAX_MODULES_PER_KEY: usize = 8;

pub const Denial = enum {
    missing_key,
    malformed_key,
    unknown_key,
    no_entitlement,
};

pub const EntryView = struct {
    name: []const u8,
    entitled_to_all: bool,
    modules: []const []const u8,
};

pub const Authz = union(enum) {
    granted: EntryView,
    denied: Denial,

    pub fn reason(self: Authz) []const u8 {
        return switch (self) {
            .granted => "authorized",
            .denied => |d| switch (d) {
                .missing_key => "API key required (X-Api-Key header)",
                .malformed_key => "malformed API key",
                .unknown_key => "unknown API key",
                .no_entitlement => "no entitlement for this module",
            },
        };
    }
};

pub const KeyEntry = struct {
    key: [64]u8 = undefined,
    key_len: usize = 0,
    name: [32]u8 = undefined,
    name_len: usize = 0,
    modules: [MAX_MODULES_PER_KEY][32]u8 = undefined,
    module_lens: [MAX_MODULES_PER_KEY]usize = .{0} ** MAX_MODULES_PER_KEY,
    module_count: usize = 0,
    all_modules: bool = false,
};

/// Validate API key format: minimum 16 characters, alphanumeric + hyphen.
pub fn isValidKeyFormat(key: []const u8) bool {
    if (key.len < 16 or key.len > 63) return false;
    for (key) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    }
    return true;
}

/// Constant-time equality (length mismatch is public: format is fixed).
fn eqlConstTime(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

pub const KeyStore = struct {
    entries: [MAX_KEYS]KeyEntry = [_]KeyEntry{.{}} ** MAX_KEYS,
    count: usize = 0,

    pub fn init() KeyStore {
        return .{};
    }

    /// Parse one key spec and add it. Errors on malformed specs — a bad
    /// key file must fail loudly, not silently reduce the store.
    pub fn add(self: *KeyStore, spec: []const u8) !void {
        if (self.count >= MAX_KEYS) return error.KeystoreFull;
        var it = std.mem.splitScalar(u8, spec, ':');
        const key = std.mem.trim(u8, it.next() orelse return error.BadKeySpec, " ");
        if (!isValidKeyFormat(key)) return error.BadKeyFormat;
        const name = std.mem.trim(u8, it.next() orelse key, " ");
        const mods = it.next(); // null => all modules

        var e = KeyEntry{};
        @memcpy(e.key[0..key.len], key);
        e.key_len = key.len;
        const n = @min(name.len, 31);
        @memcpy(e.name[0..n], name[0..n]);
        e.name_len = n;

        if (mods == null) {
            e.all_modules = true;
        } else {
            var mit = std.mem.splitScalar(u8, mods.?, ',');
            while (mit.next()) |m| {
                const mm = std.mem.trim(u8, m, " ");
                if (mm.len == 0) continue;
                if (e.module_count >= MAX_MODULES_PER_KEY) return error.TooManyModules;
                if (std.mem.eql(u8, mm, "*")) {
                    e.all_modules = true;
                    continue;
                }
                const mn = @min(mm.len, 31);
                @memcpy(e.modules[e.module_count][0..mn], mm[0..mn]);
                e.module_lens[e.module_count] = mn;
                e.module_count += 1;
            }
        }
        self.entries[self.count] = e;
        self.count += 1;
    }

    /// Load from an environment-style value: "spec;spec;...".
    /// Returns the number of keys added; malformed specs are skipped
    /// (the env var is operator input, load what is well-formed).
    pub fn loadFromEnvValue(self: *KeyStore, value: []const u8) usize {
        var added: usize = 0;
        var it = std.mem.splitScalar(u8, value, ';');
        while (it.next()) |spec| {
            const s = std.mem.trim(u8, spec, " ");
            if (s.len == 0) continue;
            self.add(s) catch continue;
            added += 1;
        }
        return added;
    }

    /// Load from a KYAML document: api_keys: ["spec", ...].
    pub fn loadFromKyamlSrc(self: *KeyStore, arena: std.mem.Allocator, src: []const u8) !usize {
        const doc = try kyaml.parse(arena, src);
        const list = doc.get("api_keys") orelse return 0;
        const items = list.asList() orelse return error.BadKeySpec;
        var added: usize = 0;
        for (items) |item| {
            const spec = item.asString() orelse continue;
            try self.add(spec);
            added += 1;
        }
        return added;
    }

    fn entryKey(e: *const KeyEntry) []const u8 {
        return e.key[0..e.key_len];
    }

    /// Authorize `api_key` for `module`. Iterates every entry with a
    /// constant-time compare — no early exit on match.
    pub fn authorize(self: *const KeyStore, api_key: []const u8, module: []const u8) Authz {
        if (api_key.len == 0) return .{ .denied = .missing_key };
        if (!isValidKeyFormat(api_key)) return .{ .denied = .malformed_key };

        var matched: ?*const KeyEntry = null;
        for (self.entries[0..self.count]) |*e| {
            if (eqlConstTime(api_key, entryKey(e))) matched = e;
        }
        const e = matched orelse return .{ .denied = .unknown_key };

        if (e.all_modules) {
            return .{ .granted = .{
                .name = e.name[0..e.name_len],
                .entitled_to_all = true,
                .modules = &.{},
            } };
        }
        for (0..e.module_count) |i| {
            if (std.mem.eql(u8, e.modules[i][0..e.module_lens[i]], module)) {
                var mods: [MAX_MODULES_PER_KEY][]const u8 = undefined;
                for (0..e.module_count) |j| mods[j] = e.modules[j][0..e.module_lens[j]];
                return .{ .granted = .{
                    .name = e.name[0..e.name_len],
                    .entitled_to_all = false,
                    .modules = mods[0..e.module_count],
                } };
            }
        }
        return .{ .denied = .no_entitlement };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "keystore: spec parsing and entitlement" {
    var ks = KeyStore.init();
    try ks.add("aaaaaaaaaaaaaaaaaaaa-soc");
    try ks.add("bbbbbbbbbbbbbbbbbbbb-readonly:readonly:telemetry,routes");
    try std.testing.expectEqual(@as(usize, 2), ks.count);

    // bare key: all modules
    const g1 = ks.authorize("aaaaaaaaaaaaaaaaaaaa-soc", "audit");
    try std.testing.expect(g1 == .granted);
    try std.testing.expect(g1.granted.entitled_to_all);

    // entitled module
    const g2 = ks.authorize("bbbbbbbbbbbbbbbbbbbb-readonly", "telemetry");
    try std.testing.expect(g2 == .granted);
    try std.testing.expect(!g2.granted.entitled_to_all);
    try std.testing.expectEqualStrings("readonly", g2.granted.name);

    // wrong module
    const d1 = ks.authorize("bbbbbbbbbbbbbbbbbbbb-readonly", "audit");
    try std.testing.expectEqual(Denial.no_entitlement, d1.denied);

    // unknown key
    const d2 = ks.authorize("cccccccccccccccccccc-unknown", "telemetry");
    try std.testing.expectEqual(Denial.unknown_key, d2.denied);

    // missing / malformed
    try std.testing.expectEqual(Denial.missing_key, ks.authorize("", "telemetry").denied);
    try std.testing.expectEqual(Denial.malformed_key, ks.authorize("short", "telemetry").denied);
}

test "keystore: env and kyaml loading" {
    var ks = KeyStore.init();
    try std.testing.expectEqual(@as(usize, 2), ks.loadFromEnvValue(
        "aaaaaaaaaaaaaaaaaaaa-one; bbbbbbbbbbbbbbbbbbbb-two:two:telemetry; bad",
    ));
    try std.testing.expect(ks.authorize("aaaaaaaaaaaaaaaaaaaa-one", "any") == .granted);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ks2 = KeyStore.init();
    const n = try ks2.loadFromKyamlSrc(arena.allocator(),
        "---\napi_keys: [\"cccccccccccccccccccc-three:three:routes,audit\",]\n");
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Denial.no_entitlement, ks2.authorize("cccccccccccccccccccc-three", "telemetry").denied);
    try std.testing.expect(ks2.authorize("cccccccccccccccccccc-three", "routes") == .granted);
}

test "keystore: malformed specs rejected loudly" {
    var ks = KeyStore.init();
    try std.testing.expectError(error.BadKeyFormat, ks.add("short"));
    try std.testing.expectError(error.BadKeyFormat, ks.add("has spaces in it!"));
    try std.testing.expectEqual(@as(usize, 0), ks.count);
}
