const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("globlin", "src/glob.zig");
    lib.setBuildMode(mode);
    lib.install();

    const main_tests = b.addTest("src/glob.zig");
    main_tests.setBuildMode(mode);

    const coverage = b.option(bool, "kcov", "Generate test coverage with kcov") orelse false;
    if (coverage) {
        main_tests.setExecCmd(&[_]?[]const u8{
            "kcov",
            "--exclude-pattern=zig/lib",
            "kcov-output",
            null,
        });
    }

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const fuzz_lib = b.addStaticLibrary("fuzz-lib", "src/fuzz.zig");
    fuzz_lib.setBuildMode(.Debug);
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;

    const fuzz_executable_name = "fuzz";
    const fuzz_exe_path = try std.fs.path.join(
        b.allocator,
        &.{ b.cache_root, fuzz_executable_name },
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
    const fuzz_debug_exe = b.addExecutable("fuzz-debug", "src/fuzz.zig");
    fuzz_debug_exe.setBuildMode(.Debug);
    // Only install fuzz-debug when the fuzz step is run
    const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe);
    fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);
}
