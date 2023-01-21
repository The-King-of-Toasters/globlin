const std = @import("std");

pub fn build(b: *std.build.Builder) void {
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
}
