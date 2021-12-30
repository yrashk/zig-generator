const std = @import("std");
const generator = @import("./generator.zig");
const extractFn = @import("./_.zig").extractFn;

fn initializer(comptime Self: type, comptime G: type, comptime F: type, comptime stateful: bool) type {
    return if (stateful) struct {
        pub const Mapper = F;

        pub fn init(inner: G, f_state: F) Self {
            return Self{
                .inner = inner,
                .state = f_state,
            };
        }
    } else struct {
        pub fn init(inner: G) Self {
            return Self{
                .inner = inner,
            };
        }
    };
}

/// `Map` creates a generator that maps yielded values from wrapped generator `G` of type `I` to type `O`
pub fn Map(comptime G: type, comptime I: type, comptime O: type, comptime F: type, comptime stateful: bool) type {
    const f = if (stateful) extractFn(F, fn (*F, I) O) else extractFn(F, fn (I) O);

    return generator.Generator(struct {
        pub const Inner = G;
        inner: G,

        state: if (stateful) F else void = undefined,
        pub usingnamespace initializer(@This(), G, F, stateful);

        pub fn generate(self: *@This(), handle: *generator.Handle(O)) !void {
            while (try self.inner.next()) |v| {
                if (stateful) try handle.yield(f(&self.state, v)) else try handle.yield(f(v));
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
    }, false);
    var g = G.init(G.Context.init(G.Context.Inner.init(ty{})));

    try expect((try g.next()).? == 1);
    try expect((try g.next()).? == 2);
    try expect((try g.next()).? == 3);
    try expect((try g.next()) == null);
    try expect(g.state == .Returned);
}

test "stateful" {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *generator.Handle(u8)) !void {
            try handle.yield(0);
            try handle.yield(1);
            try handle.yield(2);
        }
    };
    const G = Map(generator.Generator(ty, u8), u8, u8, struct {
        n: u8 = 0,
        pub fn incr(self: *@This(), i: u8) u8 {
            self.n += 1;
            return i + self.n;
        }
    }, true);
    var g = G.init(G.Context.init(G.Context.Inner.init(ty{}), G.Context.Mapper{}));

    try expect((try g.next()).? == 1);
    try expect((try g.next()).? == 3);
    try expect((try g.next()).? == 5);
    try expect((try g.next()) == null);
    try expect(g.state == .Returned);
}
