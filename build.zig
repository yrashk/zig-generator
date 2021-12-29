const deps = @import("./deps.zig");
const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("zig-generator", "src/lib.zig");
    lib.setBuildMode(mode);
    lib.install();

    const tests = b.addTest("src/tests.zig");
    tests.test_evented_io = true;
    tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&tests.step);

    const benchmarks = b.addExecutable("zig-generator-benchmarks", "benchmarks.zig");
    benchmarks.setBuildMode(.ReleaseFast);
    benchmarks.install();

    const run_benchmarks = benchmarks.run();
    run_benchmarks.step.dependOn(b.getInstallStep());

    const benchmarks_step = b.step("bench", "Run benchmarks");
    benchmarks_step.dependOn(&run_benchmarks.step);

    deps.addAllTo(lib);
    deps.addAllTo(tests);
    deps.addAllTo(benchmarks);
}
