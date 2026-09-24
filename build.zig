// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// build.zig — Aerie gateway build (self-contained; no external deps).
//
// Build graph, one repository, zero absolute paths:
//
//   ffi/zig/src/lib.zig ──> libzig_api (static)  ─┐
//   ffi/zig/include/zig_api.h (installed header) ─┤
//                                                 ├─> aerie-gateway
//   src/api/zig/main.zig ──────────────────────── ┘
//
// Estate law: ABI = Idris2 (src/abi/), FFI = Zig (ffi/zig/), API = Zig
// (src/api/zig/). The uapi surface is declared in src/abi/Gnosis.idr and
// implemented in ffi/zig — superset-compatible with
// developer-ecosystem/zig-api, which may replace it if ever published.
//
// Usage:
//   zig build                        — compile aerie-gateway (debug)
//   zig build -Doptimize=ReleaseSafe — release build
//   zig build run                    — run the gateway
//   zig build test                   — FFI + gateway unit tests
//
// Requires Zig 0.15.2+.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------------
    // FFI library: libzig_api (gnosis server + connector pool + libaerie)
    // -------------------------------------------------------------------------
    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("ffi/zig/src/lib.zig"),
        .target           = target,
        .optimize         = optimize,
        .link_libc        = true,
    });
    // The ABI layout test @cImports the header, so the FFI module itself
    // needs the include path.
    ffi_mod.addIncludePath(b.path("ffi/zig/include"));

    const ffi_lib = b.addLibrary(.{
        .name        = "zig_api",
        .root_module = ffi_mod,
        .linkage     = .static,
    });
    b.installArtifact(ffi_lib);

    // Install the C header for external consumers (Idris2 side, packagers).
    const header = b.addInstallHeaderFile(b.path("ffi/zig/include/zig_api.h"), "zig_api.h");
    b.getInstallStep().dependOn(&header.step);

    // -------------------------------------------------------------------------
    // Gateway executable
    // -------------------------------------------------------------------------
    const gateway_mod = b.createModule(.{
        .root_source_file = b.path("src/api/zig/main.zig"),
        .target           = target,
        .optimize         = optimize,
        .link_libc        = true,
    });
    gateway_mod.addIncludePath(b.path("ffi/zig/include"));
    gateway_mod.linkLibrary(ffi_lib);

    const gateway = b.addExecutable(.{
        .name        = "aerie-gateway",
        .root_module = gateway_mod,
    });
    b.installArtifact(gateway);

    // Run step.
    const run_cmd = b.addRunArtifact(gateway);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run aerie-gateway");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------------
    // Tests — FFI suite (incl. the ABI-vs-header layout assertions) and the
    // gateway suite.
    // -------------------------------------------------------------------------
    const ffi_test_mod = b.createModule(.{
        .root_source_file = b.path("ffi/zig/src/lib.zig"),
        .target           = target,
        .optimize         = optimize,
        .link_libc        = true,
    });
    ffi_test_mod.addIncludePath(b.path("ffi/zig/include"));
    const ffi_tests     = b.addTest(.{ .root_module = ffi_test_mod });
    const run_ffi_tests = b.addRunArtifact(ffi_tests);

    const gateway_test_mod = b.createModule(.{
        .root_source_file = b.path("src/api/zig/main.zig"),
        .target           = target,
        .optimize         = optimize,
        .link_libc        = true,
    });
    gateway_test_mod.addIncludePath(b.path("ffi/zig/include"));
    gateway_test_mod.linkLibrary(ffi_lib);
    const gateway_tests     = b.addTest(.{ .root_module = gateway_test_mod });
    const run_gateway_tests = b.addRunArtifact(gateway_tests);

    const test_step = b.step("test", "Run FFI + gateway unit tests");
    test_step.dependOn(&run_ffi_tests.step);
    test_step.dependOn(&run_gateway_tests.step);
}
