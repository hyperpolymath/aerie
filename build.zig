// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// build.zig — Aerie Gateway build configuration
//
// Builds the aerie-gateway binary from src/api/zig/main.zig.
// The FFI shared library is in ffi/zig/ (separate build.zig there).
//
// Usage:
//   zig build                        — compile aerie-gateway (debug)
//   zig build -Doptimize=ReleaseSafe — release build
//   zig build test                   — run unit tests
//   zig build run                    — run aerie-gateway directly
//
// External dependency: libzig_api (developer-ecosystem/zig-api)
//   Build first: cd ../developer-ecosystem/zig-api/ffi/zig && zig build
//   Then:        zig build  (uses default paths below)
//
//   Override paths for CI:
//   zig build -Dzig-api-lib-path=… -Dzig-api-include-path=…
//
// Requires Zig 0.15.2+.

const std = @import("std");

/// Default path to the directory containing libzig_api.a / libzig_api.so.
const DEFAULT_ZIG_API_LIB_PATH =
    "/var/mnt/eclipse/repos/developer-ecosystem/zig-api/ffi/zig/zig-out/lib";

/// Default path to the directory containing zig_api.h.
const DEFAULT_ZIG_API_INCLUDE_PATH =
    "/var/mnt/eclipse/repos/developer-ecosystem/zig-api/ffi/zig/zig-out/include";

/// Root source file of the zig-api Zig module (for direct Zig-level imports).
const ZIG_API_SOURCE_ROOT =
    "/var/mnt/eclipse/repos/developer-ecosystem/zig-api/ffi/zig/src/lib.zig";

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------------
    // Build options — allow callers to override zig-api library paths
    // -------------------------------------------------------------------------
    const zig_api_lib_path = b.option(
        []const u8,
        "zig-api-lib-path",
        "Directory containing libzig_api.a/.so (default: " ++ DEFAULT_ZIG_API_LIB_PATH ++ ")",
    ) orelse DEFAULT_ZIG_API_LIB_PATH;

    const zig_api_include_path = b.option(
        []const u8,
        "zig-api-include-path",
        "Directory containing zig_api.h (default: " ++ DEFAULT_ZIG_API_INCLUDE_PATH ++ ")",
    ) orelse DEFAULT_ZIG_API_INCLUDE_PATH;

    // -------------------------------------------------------------------------
    // Root module for the gateway
    // -------------------------------------------------------------------------
    const gateway_mod = b.createModule(.{
        .root_source_file = b.path("src/api/zig/main.zig"),
        .target           = target,
        .optimize         = optimize,
        .link_libc        = true,
    });

    // Wire zig-api as a named Zig module so @import("zig_api") resolves.
    // This gives aerie direct access to gnosis.zig and connector.zig Zig types
    // (ServerState, ConnectorState, pool management) in addition to the C ABI
    // symbols exposed via libzig_api.
    gateway_mod.addAnonymousImport("zig_api", .{
        .root_source_file = .{ .cwd_relative = ZIG_API_SOURCE_ROOT },
        .target           = target,
        .optimize         = optimize,
        .link_libc        = true,
    });

    // Link libzig_api so the C ABI exports (uapi_gnosis_*, uapi_connector_*,
    // uapi_init, uapi_teardown) are available.
    gateway_mod.addLibraryPath(.{ .cwd_relative = zig_api_lib_path });
    gateway_mod.addIncludePath(.{ .cwd_relative = zig_api_include_path });
    gateway_mod.linkSystemLibrary("zig_api", .{});

    // -------------------------------------------------------------------------
    // Main executable: aerie-gateway
    // -------------------------------------------------------------------------
    const gateway = b.addExecutable(.{
        .name        = "aerie-gateway",
        .root_module = gateway_mod,
    });
    b.installArtifact(gateway);

    // Run step: zig build run
    const run_cmd = b.addRunArtifact(gateway);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run aerie-gateway");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------------
    // Unit tests
    // -------------------------------------------------------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/api/zig/main.zig"),
        .target           = target,
        .optimize         = optimize,
        .link_libc        = true,
    });
    test_mod.addAnonymousImport("zig_api", .{
        .root_source_file = .{ .cwd_relative = ZIG_API_SOURCE_ROOT },
        .target           = target,
        .optimize         = optimize,
        .link_libc        = true,
    });
    test_mod.addLibraryPath(.{ .cwd_relative = zig_api_lib_path });
    test_mod.addIncludePath(.{ .cwd_relative = zig_api_include_path });
    test_mod.linkSystemLibrary("zig_api", .{});

    const tests     = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
