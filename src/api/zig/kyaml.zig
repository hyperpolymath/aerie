// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// kyaml.zig — strict KYAML parser (estate YAML policy rule Y-3:
// standards/3-practice/YAML-POLICY.adoc; Kubernetes KEP-5295 subset).
//
// KYAML is a strict subset of YAML, not a new format: every existing
// reader accepts it. Rules implemented here:
//   * a `---` document header is required;
//   * flow style throughout — `{}` for maps, `[]` for lists; the block
//     level is a FLAT map of `key: value` lines (nesting is flow);
//   * every string VALUE is double-quoted; keys are bare where
//     unambiguous; bare scalars are integers and booleans only;
//   * trailing commas are permitted; comments (`#` to end of line) are
//     permitted outside quotes and flow collections.
//
// Strictness is the point: an unquoted non-numeric scalar, a tab, a
// missing header, or a nested block are SYNTAX ERRORS, not silently
// reinterpreted YAML. Config files that parse here have exactly one
// meaning.

const std = @import("std");

pub const Error = error{
    MissingDocumentHeader,
    TabCharacter,
    NestedBlockMap,
    TrailingJunk,
    UnquotedScalar,   // string values must be double-quoted
    UnterminatedString,
    UnterminatedFlow, // { or [ not closed
    BadKey,
    EmptyDocument,
    OutOfMemory,
};

pub const Value = union(enum) {
    str: []const u8,
    int: i64,
    boolean: bool,
    map: Map,
    list: List,

    pub fn get(self: Value, key: []const u8) ?Value {
        return switch (self) {
            .map => |m| m.get(key),
            else => null,
        };
    }
    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .str => |s| s,
            else => null,
        };
    }
    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }
    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |i| i,
            else => null,
        };
    }
    pub fn asList(self: Value) ?[]const Value {
        return switch (self) {
            .list => |l| l.items,
            else => null,
        };
    }
};

pub const Entry = struct { key: []const u8, value: Value };

pub const Map = struct {
    entries: []const Entry,

    pub fn get(self: Map, key: []const u8) ?Value {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }
};

pub const List = struct { items: []const Value };

/// Parse a KYAML document into a Value tree allocated from `arena`.
/// The result aliases slices of `src` where possible (strings are copied
/// only when escapes must be resolved).
pub fn parse(arena: std.mem.Allocator, src: []const u8) Error!Value {
    var p = Parser{ .arena = arena, .src = src, .pos = 0 };

    // Document header.
    const first = (try p.nextNonEmptyLine()) orelse return Error.EmptyDocument;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " \r"), "---")) {
        return Error.MissingDocumentHeader;
    }

    var entries: std.ArrayList(Entry) = .{};
    while (try p.nextNonEmptyLine()) |line| {
        if (line.len == 0) continue;
        if (line[0] == ' ') return Error.NestedBlockMap; // flat block level only
        const e = try p.parseBlockEntry(line);
        try entries.append(arena, e);
    }
    if (entries.items.len == 0) return Error.EmptyDocument;
    return .{ .map = .{ .entries = entries.items } };
}

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize,

    /// Next line with blank/comment-only lines skipped; null at EOF.
    /// Tabs anywhere are rejected outright (KYAML: two-space indentation).
    fn nextNonEmptyLine(p: *Parser) Error!?[]const u8 {
        while (p.pos < p.src.len) {
            const nl = std.mem.indexOfScalarPos(u8, p.src, p.pos, '\n') orelse p.src.len;
            var line = p.src[p.pos..nl];
            p.pos = nl + 1;
            if (std.mem.indexOfScalar(u8, line, '\t') != null) return Error.TabCharacter;
            line = std.mem.trim(u8, line, " \r");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            return line;
        }
        return null;
    }

    fn parseBlockEntry(p: *Parser, line: []const u8) Error!Entry {
        const ci = std.mem.indexOfScalar(u8, line, ':') orelse return Error.BadKey;
        const key = std.mem.trim(u8, line[0..ci], " ");
        if (key.len == 0) return Error.BadKey;
        for (key) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return Error.BadKey;
        }
        const rest = std.mem.trim(u8, line[ci + 1 ..], " ");
        if (rest.len == 0) return Error.NestedBlockMap; // `key:` with nothing — no block nesting
        const v = try p.parseFlowValueInSlice(rest);
        return .{ .key = key, .value = v };
    }

    /// Parse one flow value covering `s` (a single block line's value):
    /// after the value only spaces and an optional trailing comment remain.
    fn parseFlowValueInSlice(p: *Parser, s: []const u8) Error!Value {
        var sub = Parser{ .arena = p.arena, .src = s, .pos = 0 };
        const v = try sub.parseFlowValue();
        var rest = std.mem.trim(u8, s[sub.pos..], " ");
        if (rest.len > 0 and rest[0] == '#') rest = rest[0..0];
        if (rest.len != 0) return Error.TrailingJunk;
        return v;
    }

    fn skipWs(p: *Parser) void {
        while (p.pos < p.src.len and p.src[p.pos] == ' ') p.pos += 1;
    }

    fn parseFlowValue(p: *Parser) Error!Value {
        p.skipWs();
        if (p.pos >= p.src.len) return Error.UnquotedScalar;
        return switch (p.src[p.pos]) {
            '"' => p.parseQuotedString(),
            '{' => p.parseFlowMap(),
            '[' => p.parseFlowList(),
            else => p.parseBareScalar(),
        };
    }

    fn parseQuotedString(p: *Parser) Error!Value {
        p.pos += 1; // opening quote
        var out: std.ArrayList(u8) = .{};
        while (p.pos < p.src.len) {
            const ch = p.src[p.pos];
            if (ch == '"') {
                p.pos += 1;
                return .{ .str = out.items };
            }
            if (ch == '\\') {
                p.pos += 1;
                if (p.pos >= p.src.len) return Error.UnterminatedString;
                const esc = p.src[p.pos];
                try out.append(p.arena, switch (esc) {
                    '"' => '"',
                    '\\' => '\\',
                    'n' => '\n',
                    't' => '\t',
                    else => return Error.UnterminatedString,
                });
                p.pos += 1;
                continue;
            }
            try out.append(p.arena, ch);
            p.pos += 1;
        }
        return Error.UnterminatedString;
    }

    fn parseBareScalar(p: *Parser) Error!Value {
        const start = p.pos;
        while (p.pos < p.src.len) : (p.pos += 1) {
            const ch = p.src[p.pos];
            if (ch == ',' or ch == '}' or ch == ']' or ch == ' ' or ch == '\n') break;
        }
        const tok = p.src[start..p.pos];
        if (std.mem.eql(u8, tok, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, tok, "false")) return .{ .boolean = false };
        if (std.fmt.parseInt(i64, tok, 10)) |i| {
            return .{ .int = i };
        } else |_| {}
        return Error.UnquotedScalar; // strings must be double-quoted
    }

    fn parseFlowMap(p: *Parser) Error!Value {
        p.pos += 1; // '{'
        var entries: std.ArrayList(Entry) = .{};
        p.skipWs();
        if (p.pos < p.src.len and p.src[p.pos] == '}') {
            p.pos += 1;
            return .{ .map = .{ .entries = entries.items } };
        }
        while (true) {
            p.skipWs();
            // key: bare (unquoted where unambiguous) or quoted
            var key: []const u8 = undefined;
            if (p.pos < p.src.len and p.src[p.pos] == '"') {
                const kv = try p.parseQuotedString();
                key = kv.str;
            } else {
                const start = p.pos;
                while (p.pos < p.src.len) : (p.pos += 1) {
                    const ch = p.src[p.pos];
                    if (ch == ':' or ch == ' ' or ch == ',') break;
                }
                key = p.src[start..p.pos];
                if (key.len == 0) return Error.BadKey;
            }
            p.skipWs();
            if (p.pos >= p.src.len or p.src[p.pos] != ':') return Error.BadKey;
            p.pos += 1;
            const value = try p.parseFlowValue();
            try entries.append(p.arena, .{ .key = key, .value = value });
            p.skipWs();
            if (p.pos >= p.src.len) return Error.UnterminatedFlow;
            if (p.src[p.pos] == ',') {
                p.pos += 1; // trailing commas permitted
                p.skipWs();
                if (p.pos < p.src.len and p.src[p.pos] == '}') {
                    p.pos += 1;
                    return .{ .map = .{ .entries = entries.items } };
                }
                continue;
            }
            if (p.src[p.pos] == '}') {
                p.pos += 1;
                return .{ .map = .{ .entries = entries.items } };
            }
            return Error.UnterminatedFlow;
        }
    }

    fn parseFlowList(p: *Parser) Error!Value {
        p.pos += 1; // '['
        var items: std.ArrayList(Value) = .{};
        p.skipWs();
        if (p.pos < p.src.len and p.src[p.pos] == ']') {
            p.pos += 1;
            return .{ .list = .{ .items = items.items } };
        }
        while (true) {
            const value = try p.parseFlowValue();
            try items.append(p.arena, value);
            p.skipWs();
            if (p.pos >= p.src.len) return Error.UnterminatedFlow;
            if (p.src[p.pos] == ',') {
                p.pos += 1;
                p.skipWs();
                if (p.pos < p.src.len and p.src[p.pos] == ']') {
                    p.pos += 1;
                    return .{ .list = .{ .items = items.items } };
                }
                continue;
            }
            if (p.src[p.pos] == ']') {
                p.pos += 1;
                return .{ .list = .{ .items = items.items } };
            }
            return Error.UnterminatedFlow;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "kyaml: flat document with all scalar kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc =
        \\---
        \\port: 4100                     # comment allowed
        \\rest: true
        \\graphql: false
        \\name: "aerie-gateway"
    ;
    const v = try parse(arena.allocator(), doc);
    const m = v.get("port").?.asInt().?;
    try std.testing.expectEqual(@as(i64, 4100), m);
    try std.testing.expect(v.get("rest").?.asBool().?);
    try std.testing.expect(!v.get("graphql").?.asBool().?);
    try std.testing.expectEqualStrings("aerie-gateway", v.get("name").?.asString().?);
}

test "kyaml: flow collections with trailing commas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc =
        \\---
        \\rate_limits: {"telemetry": 60, "routes": 30,}
        \\modules: ["telemetry", "routes", "audit",]
    ;
    const v = try parse(arena.allocator(), doc);
    try std.testing.expectEqual(@as(i64, 60), v.get("rate_limits").?.get("telemetry").?.asInt().?);
    const mods = v.get("modules").?.asList().?;
    try std.testing.expectEqual(@as(usize, 3), mods.len);
    try std.testing.expectEqualStrings("audit", mods[2].asString().?);
}

test "kyaml: escapes in quoted strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "---\nkey: \"a\\\"b\\\\c\"\n");
    try std.testing.expectEqualStrings("a\"b\\c", v.get("key").?.asString().?);
}

test "kyaml: strictness — rejects the YAML footguns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // missing header
    try std.testing.expectError(Error.MissingDocumentHeader, parse(a, "port: 1\n"));
    // unquoted string value (Norway-problem class)
    try std.testing.expectError(Error.UnquotedScalar, parse(a, "---\nname: no\n"));
    // nested block map
    try std.testing.expectError(Error.NestedBlockMap, parse(a, "---\nouter:\n  inner: 1\n"));
    // `key:` with nothing after it
    try std.testing.expectError(Error.NestedBlockMap, parse(a, "---\nouter:\n"));
    // trailing junk after a value
    try std.testing.expectError(Error.TrailingJunk, parse(a, "---\nport: 1 oops\n"));
    // unterminated flow
    try std.testing.expectError(Error.UnterminatedFlow, parse(a, "---\nm: {a: 1\n"));
    // unterminated string
    try std.testing.expectError(Error.UnterminatedString, parse(a, "---\ns: \"abc\n"));
}
