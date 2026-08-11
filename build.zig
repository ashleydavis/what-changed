const std = @import("std");

//
// The build definition.
//
// Three things come out of this file:
//
//   zig build            builds the CLI into zig-out/bin/what-changed
//   zig build test       runs every unit test in the project
//   zig build perf       builds and runs the performance benchmarks
//
// The library code is a module of its own rather than a pile of relative imports, because two
// different roots need it: the CLI at src/main.zig and the benchmarks at perf-tests/run.zig. A
// module is the only way the benchmarks can reach code that lives outside their own directory.
//
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //
    // Every piece of logic lives here, behind src/lib/lib.zig, which re-exports the modules by
    // name. Nothing in it knows about the command line or about the process, which is what makes
    // it all reachable from a unit test.
    //
    const lib_mod = b.addModule("what-changed", .{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    //
    // The CLI itself: argument parsing and the wiring from the real process into the library.
    //
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("what-changed", lib_mod);

    const exe = b.addExecutable(.{
        .name = "what-changed",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    //
    // `zig build run -- <args>` drives the freshly built CLI, which is the equivalent of
    // `bun run src/cli.ts` in the TypeScript project.
    //
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the CLI.");
    run_step.dependOn(&run_cmd.step);

    //
    // Unit tests. There are two test binaries because there are two modules: the library and the
    // CLI layer above it. Both are wired to the one `zig build test` step, so a single command
    // runs everything, the same way `bun run test` does.
    //
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run every unit test.");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    //
    // The release build: an optimised binary at the path the smoke tests look for.
    //
    // `scripts/smoke-tests.sh --binary` runs bin/<arch>/<os>/what-changed, and that script is a
    // byte-for-byte copy of the TypeScript project's, so the layout it expects is not negotiable.
    // Building to it here is what lets both ports be driven by the identical scenarios.
    //
    const release_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    release_mod.addImport("what-changed", b.addModule("what-changed-release", .{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }));

    const release_exe = b.addExecutable(.{
        .name = "what-changed",
        .root_module = release_mod,
    });

    //
    // Copied into the source tree rather than installed under the usual prefix, so `zig build
    // release` on its own puts the binary where the smoke tests look for it. Installing it would
    // land it under zig-out and need `--prefix "$PWD"` on every invocation, which is a workaround
    // leaking into every instruction that mentions building.
    //
    const install_release = b.addUpdateSourceFiles();
    install_release.addCopyFileToSource(release_exe.getEmittedBin(), releasePathFor(b, target.result));

    const release_step = b.step("release", "Build the optimised binary the smoke tests drive.");
    release_step.dependOn(&install_release.step);

    //
    // The performance benchmarks. Built in ReleaseFast whatever the rest is built as: measuring a
    // debug build would report the cost of the safety checks rather than the cost of the tool.
    //
    const perf_mod = b.createModule(.{
        .root_source_file = b.path("perf-tests/run.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    perf_mod.addImport("what-changed", b.addModule("what-changed-perf", .{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }));

    const perf = b.addExecutable(.{
        .name = "perf",
        .root_module = perf_mod,
    });
    b.installArtifact(perf);

    const run_perf = b.addRunArtifact(perf);
    if (b.args) |args| {
        run_perf.addArgs(args);
    }
    const perf_step = b.step("perf", "Run the performance benchmarks.");
    perf_step.dependOn(&run_perf.step);

    //
    // The benchmark harness has unit tests of its own, because a harness that measures the wrong
    // thing reports numbers nobody can act on. They run at a tiny tree size, so the test suite does
    // not pay for a twenty-thousand-file tree.
    //
    const perf_tests = b.addTest(.{ .root_module = perf_mod });
    test_step.dependOn(&b.addRunArtifact(perf_tests).step);
}

//
// Where the release binary goes, relative to the repository root.
//
// `scripts/smoke-tests.sh --binary` hard-codes this layout, so it is not negotiable.
//
fn releasePathFor(b: *std.Build, target: std.Target) []const u8 {
    const architecture = switch (target.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => @tagName(target.cpu.arch),
    };

    const operating_system = switch (target.os.tag) {
        .linux => "linux",
        .macos => "mac",
        .windows => "win",
        else => @tagName(target.os.tag),
    };

    const name = if (target.os.tag == .windows) "what-changed.exe" else "what-changed";
    return b.fmt("bin/{s}/{s}/{s}", .{ architecture, operating_system, name });
}
