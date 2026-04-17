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
// Requires Zig 0.15.2+.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------------
    // Root module for the gateway
    // -------------------------------------------------------------------------
    const gateway_mod = b.createModule(.{
        .root_source_file = b.path("src/api/zig/main.zig"),
        .target           = target,
        .optimize         = optimize,
    });

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
    });
    const tests     = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
