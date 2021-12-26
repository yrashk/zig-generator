const deps = @import("./deps.zig");
const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("zig-generator", "src/lib.zig");
    lib.setBuildMode(mode);
    lib.install();

    const tests = b.addTest("src/lib.zig");
    tests.test_evented_io = true;
    tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&tests.step);

    deps.addAllTo(lib);
    deps.addAllTo(tests);
}
