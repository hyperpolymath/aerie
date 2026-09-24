// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// build.zig — standalone FFI build (cd ffi/zig && zig build).
//
// Emits the same libzig_api the root build produces, plus the libaerie
// alias (Idris2 consumers link -laerie per src/abi/Foreign.idr) and the
// installed C header. The root build.zig is the canonical entry point;
// this one exists for FFI-focused development and packaging.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target           = target,
        .optimize         = optimize,
        .link_libc        = true,
    });
    mod.addIncludePath(b.path("include"));

    // Shared library: libzig_api.so
    const shared = b.addLibrary(.{
        .name        = "zig_api",
        .root_module = mod,
        .linkage     = .dynamic,
        .version     = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    b.installArtifact(shared);

    // Static library: libzig_api.a
    const static = b.addLibrary(.{
        .name        = "zig_api",
        .root_module = mod,
        .linkage     = .static,
    });
    b.installArtifact(static);

    // Alias for the Idris2 side (Foreign.idr declares `libaerie`).
    const aerie_alias = b.addLibrary(.{
        .name        = "aerie",
        .root_module = mod,
        .linkage     = .static,
    });
    b.installArtifact(aerie_alias);

    // C header.
    const header = b.addInstallHeaderFile(b.path("include/zig_api.h"), "zig_api.h");
    b.getInstallStep().dependOn(&header.step);

    // Tests (incl. ABI layout assertions against the header).
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target           = target,
        .optimize         = optimize,
        .link_libc        = true,
    });
    test_mod.addIncludePath(b.path("include"));
    const tests     = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run FFI unit tests");
    test_step.dependOn(&run_tests.step);
}
