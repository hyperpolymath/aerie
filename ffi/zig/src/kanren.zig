// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// kanren.zig — UNTRUSTED forensic search engine (interface ③, Zig side).
//
// Design: docs/design/forensic-stack.adoc. This engine is deliberately
// outside the trust boundary: it emits candidate attack paths as flat
// RawStep derivations, and the Idris2 kernel (src/abi/Forensics.idr,
// checkReach) accepts or rejects each one against the evidence. A bug
// here can only lose answers, never forge one.
//
// Scope (FS-0 scaffold): an in-process evidence table + depth-bounded
// DFS reachability with fact-id-carrying steps. The relational
// (miniKanren-style) core, file ingestion and fibre enumeration are
// later phases; the C ABI below is the stable surface they grow into.
//
// Rules (prototype set, mirrored by the kernel's side conditions):
//   lateral : internal -> internal on ports 445/3389/22/5985
//   exfil   : internal -> external (any port), must end a path
//   entry   : external -> internal (any port), must start a path
// "internal" = 10.x.x.x prefix, matching Internal in Forensics.idr.

const std = @import("std");
const core = @import("core.zig");

// ---------------------------------------------------------------------------
// Wire types (must match zig_api.h; asserted by tests)
// ---------------------------------------------------------------------------

pub const RULE_LATERAL: u8 = 0;
pub const RULE_EXFIL: u8 = 1;
pub const RULE_ENTRY: u8 = 2;

pub const RawStep = extern struct {
    fact_id: u32,
    rule: u8,
    _pad: u8 = 0,
    _pad2: u16 = 0,
};

pub const RawDeriv = extern struct {
    steps: ?[*]const RawStep,
    len: u32,
};

const MAX_FLOWS: usize = 4096;
const MAX_DERIVS: usize = 256;
const MAX_STEPS_PER_DERIV: usize = 64;

pub const Flow = struct {
    fid: u32,
    src: [64]u8 = undefined,
    src_len: usize = 0,
    dst: [64]u8 = undefined,
    dst_len: usize = 0,
    port: u16,
    bytes: u64,

    fn srcSlice(self: *const Flow) []const u8 {
        return self.src[0..self.src_len];
    }
    fn dstSlice(self: *const Flow) []const u8 {
        return self.dst[0..self.dst_len];
    }
};

// ---------------------------------------------------------------------------
// Evidence table (per-call arena for derivations; table is process state)
// ---------------------------------------------------------------------------

var flows: [MAX_FLOWS]Flow = undefined;
var flow_count: usize = 0;
var flow_mutex: std.Thread.Mutex = .{};

var arena_inst: ?std.heap.ArenaAllocator = null;

fn engineAlloc() std.mem.Allocator {
    if (arena_inst == null) {
        arena_inst = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    }
    return arena_inst.?.allocator();
}

fn isInternal(host: []const u8) bool {
    return std.mem.startsWith(u8, host, "10.");
}

fn classify(f: *const Flow) u8 {
    const src_in = isInternal(f.srcSlice());
    const dst_in = isInternal(f.dstSlice());
    if (src_in and dst_in) {
        return switch (f.port) {
            445, 3389, 22, 5985 => RULE_LATERAL,
            else => 255, // internal-internal but not a lateral port
        };
    }
    if (src_in and !dst_in) return RULE_EXFIL;
    if (!src_in and dst_in) return RULE_ENTRY;
    return 255; // external -> external: not in the prototype rule set
}

// ---------------------------------------------------------------------------
// C ABI (declared in src/abi/Forensics.idr; header: zig_api.h)
// ---------------------------------------------------------------------------

/// Add one observed flow to the evidence table.
/// Returns the fact-id, or 0xFFFFFFFF on overflow / bad input.
pub export fn kanren_add_flow(
    src: ?[*:0]const u8,
    dst: ?[*:0]const u8,
    port: u16,
    bytes: u64,
) callconv(.c) u32 {
    const s = std.mem.span(src orelse return 0xFFFFFFFF);
    const d = std.mem.span(dst orelse return 0xFFFFFFFF);
    flow_mutex.lock();
    defer flow_mutex.unlock();
    if (flow_count >= MAX_FLOWS or s.len >= 64 or d.len >= 64) return 0xFFFFFFFF;
    const f = &flows[flow_count];
    f.* = .{ .fid = @intCast(flow_count), .port = port, .bytes = bytes };
    @memcpy(f.src[0..s.len], s);
    f.src_len = s.len;
    @memcpy(f.dst[0..d.len], d);
    f.dst_len = d.len;
    flow_count += 1;
    return f.fid;
}

/// Clear the evidence table and free any derivation arena.
pub export fn kanren_clear() callconv(.c) void {
    flow_mutex.lock();
    defer flow_mutex.unlock();
    flow_count = 0;
    kanren_free();
}

/// Free the derivation arena. Callers hold nothing after this.
pub export fn kanren_free() callconv(.c) void {
    if (arena_inst) |*a| {
        a.deinit();
        arena_inst = null;
    }
}

/// Depth-bounded search: candidate paths from `src` that end in an exfil
/// step. Fills `out` with an array of RawDeriv (allocated in the arena,
/// valid until kanren_free). Returns the derivation count; 0 is "no
/// candidate within budget", which is DISTINCT from "no path exists" —
/// the trusted checker and the caller keep that honesty (tropical budget
/// seam: max_depth is a declared resource grade on the query).
pub export fn kanren_attack_paths(
    src: ?[*:0]const u8,
    out: ?*?[*]const RawDeriv,
    max_depth: u32,
) callconv(.c) u32 {
    const source = std.mem.span(src orelse return 0);
    const outp = out orelse return 0;
    if (max_depth == 0 or max_depth > MAX_STEPS_PER_DERIV) return 0;

    flow_mutex.lock();
    defer flow_mutex.unlock();

    const alloc = engineAlloc();
    var derivs = alloc.alloc(RawDeriv, MAX_DERIVS) catch return 0;
    var deriv_count: usize = 0;
    var steps_buf: [MAX_STEPS_PER_DERIV]RawStep = undefined;

    // DFS over lateral edges; emit when an exfil edge closes the path.
    const found = dfs(source, &steps_buf, 0, max_depth, &derivs, &deriv_count, alloc);

    if (!found or deriv_count == 0) {
        outp.* = null;
        return 0;
    }
    outp.* = derivs.ptr;
    return @intCast(deriv_count);
}

fn dfs(
    current: []const u8,
    steps: []RawStep,
    depth: usize,
    max_depth: u32,
    derivs: *[]RawDeriv,
    deriv_count: *usize,
    alloc: std.mem.Allocator,
) bool {
    if (deriv_count.* >= MAX_DERIVS) return true;
    for (flows[0..flow_count]) |*f| {
        const rule = classify(f);
        switch (rule) {
            RULE_LATERAL => {
                if (!std.mem.eql(u8, f.srcSlice(), current)) continue;
                if (depth >= max_depth) continue;
                steps[depth] = .{ .fact_id = f.fid, .rule = RULE_LATERAL };
                _ = dfs(f.dstSlice(), steps, depth + 1, max_depth, derivs, deriv_count, alloc);
            },
            RULE_EXFIL => {
                if (!std.mem.eql(u8, f.srcSlice(), current)) continue;
                if (depth >= max_depth) continue;
                steps[depth] = .{ .fact_id = f.fid, .rule = RULE_EXFIL };
                const n = depth + 1;
                const owned = alloc.dupe(RawStep, steps[0..n]) catch continue;
                derivs.*[deriv_count.*] = .{ .steps = owned.ptr, .len = @intCast(n) };
                deriv_count.* += 1;
            },
            else => {},
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests (the trusted checker's negative tests live in Idris2, FS-1)
// ---------------------------------------------------------------------------

test "kanren: raw structs match zig_api.h layout" {
    const h = @cImport({
        @cInclude("zig_api.h");
    });
    try std.testing.expectEqual(@sizeOf(h.RawStep), @sizeOf(RawStep));
    try std.testing.expectEqual(@offsetOf(h.RawStep, "rule"), @offsetOf(RawStep, "rule"));
    try std.testing.expectEqual(@sizeOf(h.RawDeriv), @sizeOf(RawDeriv));
    try std.testing.expectEqual(@offsetOf(h.RawDeriv, "len"), @offsetOf(RawDeriv, "len"));
}

test "kanren: chain then exfil is found with fact ids" {
    kanren_clear();
    defer kanren_clear();
    _ = kanren_add_flow("10.0.0.5", "10.0.0.12", 445, 1000); // lateral
    _ = kanren_add_flow("10.0.0.12", "10.0.0.20", 3389, 2000); // lateral
    _ = kanren_add_flow("10.0.0.20", "198.51.100.9", 443, 750_000_000); // exfil
    _ = kanren_add_flow("203.0.113.7", "10.0.0.5", 80, 500); // entry (unused from this src)

    var derivs: ?[*]const RawDeriv = null;
    const n = kanren_attack_paths("10.0.0.5", &derivs, 8);
    try std.testing.expectEqual(@as(u32, 1), n);
    const d = derivs.?[0];
    try std.testing.expectEqual(@as(u32, 3), d.len);
    try std.testing.expectEqual(@as(u32, 0), d.steps.?[0].fact_id);
    try std.testing.expectEqual(RULE_LATERAL, d.steps.?[0].rule);
    try std.testing.expectEqual(@as(u32, 1), d.steps.?[1].fact_id);
    try std.testing.expectEqual(@as(u32, 2), d.steps.?[2].fact_id);
    try std.testing.expectEqual(RULE_EXFIL, d.steps.?[2].rule);
    kanren_free();
}

test "kanren: budget distinguishes no-answer-in-budget" {
    kanren_clear();
    defer kanren_clear();
    _ = kanren_add_flow("10.0.0.5", "10.0.0.12", 445, 1000);
    _ = kanren_add_flow("10.0.0.12", "10.0.0.20", 3389, 2000);
    _ = kanren_add_flow("10.0.0.20", "198.51.100.9", 443, 750_000_000);

    var derivs: ?[*]const RawDeriv = null;
    // Depth budget 2 cannot carry the 3-step path: no candidate —
    // distinct from "no path exists" (depth 3 finds it).
    try std.testing.expectEqual(@as(u32, 0), kanren_attack_paths("10.0.0.5", &derivs, 2));
    try std.testing.expectEqual(@as(u32, 1), kanren_attack_paths("10.0.0.5", &derivs, 3));
    kanren_free();
}

test "kanren: non-lateral internal port never appears" {
    kanren_clear();
    defer kanren_clear();
    _ = kanren_add_flow("10.0.0.5", "10.0.0.12", 8080, 1000); // internal but not lateral
    _ = kanren_add_flow("10.0.0.12", "198.51.100.9", 443, 10);

    var derivs: ?[*]const RawDeriv = null;
    try std.testing.expectEqual(@as(u32, 0), kanren_attack_paths("10.0.0.5", &derivs, 8));
    kanren_free();
}
