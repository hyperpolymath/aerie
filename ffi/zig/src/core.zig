// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// core.zig — shared result codes, error slot and constants for the
// in-reco zig_api FFI (declared in src/abi/Gnosis.idr).
//
// The wire values are fixed by ffi/zig/include/zig_api.h and must not
// drift; the comptime block below pins them to the header contract.

const std = @import("std");

/// Result codes — UAPI_* tags (zig_api.h).
pub const Result = enum(u8) {
    ok = 0,
    err = 1,
    invalid_param = 2,
    out_of_memory = 3,
    null_pointer = 4,
    path_denied = 5,
    process_failed = 6,
    timeout = 7,
    not_found = 8,
    already_exists = 9,
    slot_exhausted = 10,

    pub fn toU8(self: Result) u8 {
        return @intFromEnum(self);
    }
};

/// Server states — UAPI_SERVER_* tags.
pub const ServerState = enum(u8) {
    idle = 0,
    listening = 1,
    draining = 2,
    stopped = 3,
};

/// Connector states — UAPI_CONNECTOR_* tags.
pub const ConnectorState = enum(u8) {
    disconnected = 0,
    connecting = 1,
    connected = 2,
    degraded = 3,
    failed = 4,
    draining = 5,
};

/// HTTP methods — UAPI_METHOD_* tags.
pub const HttpMethod = enum(u8) {
    get = 0,
    post = 1,
    put = 2,
    delete = 3,
    head = 4,
    options = 5,
    patch = 6,

    pub fn text(self: HttpMethod) []const u8 {
        return switch (self) {
            .get => "GET",       .post => "POST",     .put => "PUT",
            .delete => "DELETE", .head => "HEAD",     .options => "OPTIONS",
            .patch => "PATCH",
        };
    }
};

comptime {
    // Pin the tag values to the header contract at compile time.
    std.debug.assert(@intFromEnum(Result.ok) == 0);
    std.debug.assert(@intFromEnum(Result.slot_exhausted) == 10);
    std.debug.assert(@intFromEnum(ServerState.listening) == 1);
    std.debug.assert(@intFromEnum(ConnectorState.draining) == 5);
    std.debug.assert(@intFromEnum(HttpMethod.patch) == 6);
}

/// Library version (kept in step with the aerie gateway version).
pub const VERSION = "0.1.0";

/// Thread-local last-error slot (mirrors the libaerie surface convention).
threadlocal var last_error_buf: [256]u8 = undefined;
threadlocal var last_error_len: usize = 0;

/// Record an error message for uapi-level diagnostics.
pub fn setError(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&last_error_buf, fmt, args) catch {
        last_error_len = last_error_buf.len;
        return;
    };
    last_error_len = written.len;
}

/// Read the last error recorded on this thread (empty when none).
pub fn lastError() []const u8 {
    return last_error_buf[0..last_error_len];
}

pub fn clearError() void {
    last_error_len = 0;
}
