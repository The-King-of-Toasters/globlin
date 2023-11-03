const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "globlin",
        .root_source_file = .{ .path = "src/glob.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/glob.zig" },
        .target = target,
        .optimize = optimize,
    });

    const coverage = b.option(bool, "kcov", "Generate test coverage with kcov") orelse false;
    if (coverage) {
        main_tests.setExecCmd(&[_]?[]const u8{
            "kcov",
            "--exclude-pattern=zig/lib",
            "kcov-output",
            null,
        });
    }

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const fuzz_lib = b.addStaticLibrary(.{
        .name = "globlin-fuzz",
        .root_source_file = .{ .path = "src/glob.zig" },
        .target = target,
        .optimize = .Debug,
    });
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;
    fuzz_lib.force_pic = true;

    const fuzz_executable_name = "fuzz";
    const fuzz_exe_path = try std.fs.path.join(
        b.allocator,
        &.{ b.cache_root.path.?, fuzz_executable_name },
    );

    const fuzz_compile = b.addSystemCommand(&.{ "afl-clang-lto", "-o", fuzz_exe_path });
    fuzz_compile.addArtifactArg(fuzz_lib);
    const fuzz_install = b.addInstallBinFile(.{ .path = fuzz_exe_path }, fuzz_executable_name);
    const fuzz_compile_run = b.step(
        "fuzz",
        "Build executable for fuzz testing using afl-clang-lto",
    );
    fuzz_compile_run.dependOn(&fuzz_compile.step);
    fuzz_compile_run.dependOn(&fuzz_install.step);

    // Compile a companion exe for debugging crashes
    const fuzz_debug_exe = b.addExecutable(.{
        .name = "fuzz-debug",
        .root_source_file = .{ .path = "src/fuzz.zig" },
        .target = target,
        .optimize = .Debug,
    });
    // Only install fuzz-debug when the fuzz step is run
    const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe, .{});
    fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);
}
