const std = @import("std");
const Handle = @import("./src/lib.zig").Handle;
const Generator = @import("./src/lib.zig").Generator;

pub const io_mode = .evented;

const expect = std.testing.expect;

pub fn main() !void {
    try benchReturnVsFinish();
}

pub fn benchReturnVsFinish() !void {
    const tyFinish = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8, u8)) !u8 {
            try handle.yield(0);
            try handle.yield(1);
            try handle.yield(2);
            handle.finish(3);
            unreachable;
        }
    };

    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8, u8)) !u8 {
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
    try expect(g.state.Done == 3);

    const Gf = Generator(tyFinish, u8);
    var gf = Gf.init(tyFinish{});

    _ = try gf.drain();
    try expect(gf.state.Done == 3);

    // measure performance

    const bench = @import("bench");
    try bench.benchmark(struct {
        pub fn return_value() !void {
            var gen = G.init(ty{});
            _ = try gen.drain();
            try expect(gen.state.Done == 3);
        }
        pub fn finish() !void {
            var gen = Gf.init(tyFinish{});
            _ = try gen.drain();
            try expect(gen.state.Done == 3);
        }
    });
}
