// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// lib.zig — root of libzig_api: the in-repo gnosis server + connector
// pool (uapi_* surface, declared in src/abi/Gnosis.idr) and the libaerie
// surface (aerie_* exports, declared in src/abi/Foreign.idr).
//
// One library, two ABI names: the gateway links -lzig_api (zig_api.h) and
// Idris2 consumers link -laerie (Foreign.idr). Both names ship the same
// symbol set; the alias is honest, not a fork.

const std = @import("std");
const core = @import("core.zig");
const gnosis = @import("gnosis.zig");
const connector = @import("connector.zig");
const aerie = @import("aerie.zig");
const kanren = @import("kanren.zig");

// Force analysis of every exporting module so all C ABI symbols ship.
comptime {
    _ = gnosis;
    _ = connector;
    _ = aerie;
    _ = kanren;
}

/// Null-terminated library version.
pub export fn uapi_version() callconv(.c) [*:0]const u8 {
    return core.VERSION;
}

var initialized = std.atomic.Value(bool).init(false);

/// One-time library init. Pools are statically zeroed; this is an
/// idempotent gate for contract compliance, not allocation.
pub export fn uapi_init() callconv(.c) u8 {
    if (initialized.load(.acquire)) return core.Result.ok.toU8();
    initialized.store(true, .release);
    return core.Result.ok.toU8();
}

/// Tear down every live server and connector slot.
pub export fn uapi_teardown() callconv(.c) void {
    if (!initialized.swap(false, .acq_rel)) return;
    var handle: u64 = 1;
    while (handle <= 16) : (handle += 1) gnosis.uapi_gnosis_destroy(handle);
    var slot: u8 = 0;
    while (slot < 64) : (slot += 1) connector.uapi_connector_destroy(slot);
    core.clearError();
}

test "lib: init/teardown idempotence" {
    try std.testing.expectEqual(@as(u8, 0), uapi_init());
    try std.testing.expectEqual(@as(u8, 0), uapi_init()); // idempotent
    uapi_teardown();
    uapi_teardown(); // safe when not initialised
    try std.testing.expectEqualStrings("0.1.0", std.mem.span(uapi_version()));
}
