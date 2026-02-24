// Aerie FFI Implementation
//
// This module implements the C-compatible FFI declared in src/abi/Foreign.idr
// All types and layouts must match the Idris2 ABI definitions.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

// Version information
const VERSION = "0.1.0";

//==============================================================================
// Aerie Data Types (must match src/abi/Types.idr)
//==============================================================================

pub const TelemetrySample = extern struct {
    timestamp: u64,
    latency_ms: f64,
    jitter_ms: f32,
    packet_loss: f64,
};

pub const RouteHop = extern struct {
    hop: i32,
    ip: [*:0]const u8,
    asn: [*:0]const u8,
    rtt_ms: f64,
};

pub const AuditEvent = extern struct {
    event_id: [*:0]const u8,
    valid_time: u64,
    tx_time: u64,
    severity: [*:0]const u8,
    message: [*:0]const u8,
};

pub const Result = enum(c_int) {
    ok = 0,
    @"error" = 1,
    invalid_param = 2,
    out_of_memory = 3,
    null_pointer = 4,
};

pub const Handle = opaque {
    allocator: std.mem.Allocator,
    initialized: bool,
};

//==============================================================================
// Library Lifecycle
//==============================================================================

export fn aerie_init() ?*Handle {
    const allocator = std.heap.c_allocator;
    const handle = allocator.create(Handle) catch return null;
    handle.* = .{
        .allocator = allocator,
        .initialized = true,
    };
    return handle;
}

export fn aerie_free(handle: ?*Handle) void {
    const h = handle orelse return;
    const allocator = h.allocator;
    allocator.destroy(h);
}
