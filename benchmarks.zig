const std = @import("std");
const Handle = @import("./src/lib.zig").Handle;
const Generator = @import("./src/lib.zig").Generator;

pub const io_mode = .evented;

const expect = std.testing.expect;

pub fn main() !void {
    try benchDrain();
    try benchGeneratorVsCallback();
}

pub fn benchDrain() !void {
    std.debug.print("\n=== Benchmark: generator draining\n", .{});

    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8)) !u8 {
            try handle.yield(0);
            try handle.yield(1);
            try handle.yield(2);
            return 3;
        }
    };

    // ensure they behave as expected
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    _ = try g.drain();
    try expect(g.state.Returned == 3);

    // measure performance

    const bench = @import("bench");
    try bench.benchmark(struct {
        pub fn return_value() !void {
            var gen = G.init(ty{});
            _ = try gen.drain();
            try expect(gen.state.Returned == 3);
        }
    });
}

pub fn benchGeneratorVsCallback() !void {
    const W = fn (u8) callconv(.Async) anyerror!void;

    const busy_work = struct {
        fn do(_: u8) callconv(.Async) !void {
            std.os.nanosleep(0, 10);
        }
    };

    const no_work = struct {
        fn do(_: u8) callconv(.Async) !void {}
    };
    _ = no_work;

    std.debug.print("\n=== Benchmark: generator vs callback\n", .{});

    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8)) !u8 {
            try handle.yield(0);
            try handle.yield(1);
            try handle.yield(2);
            return 3;
        }
    };

    const tyc = struct {
        pub fn run(_: *@This(), cb: fn (u8) callconv(.Async) anyerror!void) !u8 {
            var frame_buffer: [64]u8 align(@alignOf(@Frame(busy_work.do))) = undefined;
            var result: anyerror!void = undefined;
            suspend {
                resume @frame();
            }
            try await @asyncCall(&frame_buffer, &result, cb, .{0});
            suspend {
                resume @frame();
            }
            try await @asyncCall(&frame_buffer, &result, cb, .{1});
            suspend {
                resume @frame();
            }
            try await @asyncCall(&frame_buffer, &result, cb, .{2});
            return 3;
        }
    };

    // ensure they behave as expected
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    _ = try g.drain();
    try expect(g.state.Returned == 3);

    // measure performance

    const bench = @import("bench");
    try bench.benchmark(struct {
        pub const args = [_]W{
            no_work.do,
            busy_work.do,
        };

        pub const arg_names = [_][]const u8{
            "no work",
            "busy work",
        };

        pub fn generator(w: W) !void {
            var gen = G.init(ty{});
            var frame_buffer: [64]u8 align(@alignOf(@Frame(busy_work.do))) = undefined;
            var result: anyerror!void = undefined;
            while (try gen.next()) |v| {
                try await @asyncCall(&frame_buffer, &result, w, .{v});
            }
            try expect(gen.state.Returned == 3);
        }

        pub fn callback(w: W) !void {
            var c = tyc{};
            try expect((try await async c.run(w)) == 3);
        }
    });
}
