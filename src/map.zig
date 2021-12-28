const std = @import("std");
const generator = @import("./generator.zig");
const extractFn = @import("./_.zig").extractFn;

/// `Map` creates a generator that maps yielded values from wrapped generator `G` of type `I` to type `O`
pub fn Map(comptime G: type, comptime I: type, comptime O: type, comptime F: type) type {
    const f = extractFn(F, fn (I) O);
    return generator.Generator(struct {
        pub const Inner = G;
        inner: G,
        pub fn init(inner: G) @This() {
            return @This(){ .inner = inner };
        }
        pub fn generate(self: *@This(), handle: *generator.Handle(O)) !void {
            while (try self.inner.next()) |v| {
                try handle.yield(f(v));
            }
        }
    }, I);
}

test {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *generator.Handle(u8)) !void {
            try handle.yield(0);
            try handle.yield(1);
            try handle.yield(2);
        }
    };
    const G = Map(generator.Generator(ty, u8), u8, u8, struct {
        pub fn incr(i: u8) u8 {
            return i + 1;
        }
    });
    var g = G.init(G.Context.init(G.Context.Inner.init(ty{})));

    try expect((try g.next()).? == 1);
    try expect((try g.next()).? == 2);
    try expect((try g.next()).? == 3);
    try expect((try g.next()) == null);
    try expect(g.state == .Returned);
}
