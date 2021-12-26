//! This module provides functionality to define async generator functions.
//!
//! It allows one to develop linear algorithms that yield values at certain
//! points without having to maintain re-entrancy manually.
//!
//! ```
//! const std = @import("std");
//! const gen = @import("./src/lib.zig");
//! 
//! const Ty = struct {
//!     pub fn generate(_: *@This(), handle: *gen.Handle(u8)) !u8 {
//!         handle.yield(0);
//!         handle.yield(1);
//!         handle.yield(2);
//!         return 3;
//!     }
//! };
//! 
//! const G = gen.Generator(Ty, u8);
//! 
//! pub const io_mode = .evented;
//! 
//! pub fn main() !void {
//!     var g = G.init(Ty{});
//! 
//!     std.debug.assert((try g.next()).? == 0);
//!     std.debug.assert((try g.next()).? == 1);
//!     std.debug.assert((try g.next()).? == 2);
//!     std.debug.assert((try g.next()) == null);
//!     std.debug.assert(g.return_value.? == 3);
//! }
//! ```

const std = @import("std");
const assert = std.debug.assert;

/// Generator handle, to be used in Handle's Ctx type
pub fn Handle(comptime T: type) type {
    return struct {
        const Self = @This();

        next_result: T = undefined,
        is_done: bool = false,
        frame: anyframe = undefined,
        gen_frame: anyframe = undefined,
        gen_suspended: bool = false,
        yielded: bool = false,

        /// Yields a value
        pub fn yield(self: *Self, t: T) void {
            self.next_result = t;
            self.yielded = true;

            suspend {
                self.frame = @frame();
                self.resumeGenerator();
            }

            self.yielded = false;
        }

        fn done(self: *Self) void {
            self.is_done = true;
            self.yielded = false;
            self.resumeGenerator();
        }

        fn resumeGenerator(self: *Self) void {
            if (self.gen_suspended) {
                self.gen_suspended = false;
                resume self.gen_frame;
            }
        }
    };
}

/// Generator type allows an async function to yield multiple
/// values, and return an error or a result.
///
/// Ctx type must be a struct and it must have the following function:
///
/// * `generate(self: *@This(), handle: *generator.Handle(T)) !PayloadType`
///
/// where T is the type of value yielded by the generator.
pub fn Generator(comptime Ctx: type, comptime T: type) type {
    const ty = @typeInfo(Ctx);
    comptime {
        assert(ty == .Struct);
        assert(@hasDecl(Ctx, "generate"));
    }

    const generate_fn = Ctx.generate;
    const generate_fn_info = @typeInfo(@TypeOf(generate_fn));

    assert(generate_fn_info == .Fn);
    assert(generate_fn_info.Fn.args.len == 2);

    const arg1_tinfo = @typeInfo(generate_fn_info.Fn.args[0].arg_type.?);
    const arg2_tinfo = @typeInfo(generate_fn_info.Fn.args[1].arg_type.?);
    const ret_tinfo = @typeInfo(generate_fn_info.Fn.return_type.?);

    // context
    assert(arg1_tinfo == .Pointer);
    assert(arg1_tinfo.Pointer.child == Ctx);

    // Handle
    assert(arg2_tinfo == .Pointer);
    assert(arg2_tinfo.Pointer.child == Handle(T));

    assert(ret_tinfo == .ErrorUnion);

    return struct {
        const Self = @This();
        const Err = ret_tinfo.ErrorUnion.error_set;
        pub const Return = ret_tinfo.ErrorUnion.payload;

        pub const Context = Ctx;

        handle: Handle(T) = Handle(T){},
        state: enum { Initialized, Started, Done },

        frame: @Frame(generator) = undefined,

        ctx: Ctx,
        err: ?Err = null,

        /// Return value, `null` if the generator function hasn't returned yet
        return_value: ?Return = null,

        /// Initializes a generator
        pub fn init(ctx: Ctx) Self {
            return Self{
                .ctx = ctx,
                .state = .Initialized,
            };
        }

        /// Returns the underline context
        pub fn context(self: *Self) *Ctx {
            return &self.ctx;
        }

        fn generator(self: *Self) @Type(ret_tinfo) {
            defer self.handle.done();

            return try generate_fn(&self.ctx, &self.handle);
        }

        fn awaitActionable(self: *Self) void {
            if (!self.handle.yielded and !self.handle.is_done) {
                suspend {
                    self.handle.gen_frame = @frame();
                    self.handle.gen_suspended = true;
                }
            }
        }

        /// Returns the next yielded value, or `null` if the generator has completed
        ///
        /// .return_value field can be used to retrieve the return value of the generator
        /// once it has completed.
        ///
        /// `next()` also propagates errors returned by the generator function.
        pub fn next(self: *Self) Err!?T {
            switch (self.state) {
                .Initialized => {
                    self.state = .Started;
                    self.frame = async self.generator();
                },
                .Started => {
                    resume self.handle.frame;
                },
                .Done => return null,
            }

            self.awaitActionable();

            if (self.handle.is_done) {
                self.state = .Done;
                self.return_value = await self.frame catch |err| error_handler: {
                    self.err = err;
                    break :error_handler null;
                };

                if (self.err) |err| {
                    return err;
                }

                return null;
            }

            return self.handle.next_result;
        }

        /// Drains the generator until it is done, returning a pointer to `self.return_value`
        pub fn drain(self: *Self) !*Return {
            while (try self.next()) |_| {}
            return &self.return_value.?;
        }
    };
}

test "basic generator" {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8)) !void {
            handle.yield(0);
            handle.yield(1);
            handle.yield(2);
        }
    };
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try expect((try g.next()).? == 0);
    try expect((try g.next()).? == 1);
    try expect((try g.next()).? == 2);
    try expect((try g.next()) == null);
    try expect(g.state == .Done);
    try expect((try g.next()) == null);
}

test "generator with async i/o" {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8)) !void {
            const bytes = "test" ** 100;
            var fbs = std.io.fixedBufferStream(bytes);
            const reader = fbs.reader();

            while (true) {
                const byte = reader.readByte() catch return;
                handle.yield(byte);
            }
        }
    };
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    var bytes: usize = 0;

    while (try g.next()) |_| {
        bytes += 1;
    }

    try expect(bytes > 0);
}

test "context" {
    const expect = std.testing.expect;

    const ty = struct {
        a: u8 = 1,

        pub fn generate(_: *@This(), handle: *Handle(u8)) !void {
            handle.yield(0);
            handle.yield(1);
            handle.yield(2);
        }
    };

    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try expect(g.context().a == 1);
}

test "errors in generators" {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8)) !void {
            handle.yield(0);
            handle.yield(1);
            return error.SomeError;
        }
    };
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try expect((try g.next()).? == 0);
    try expect((try g.next()).? == 1);
    _ = g.next() catch |err| {
        try expect(g.state == .Done);
        try expect((try g.next()) == null);
        switch (err) {
            error.SomeError => {
                return;
            },
            else => {
                @panic("incorrect error has been captured");
            },
        }
        return;
    };
    @panic("error should have been generated");
}

test "return value in generator" {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8)) !u8 {
            handle.yield(0);
            handle.yield(1);
            handle.yield(2);
            return 3;
        }
    };
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try expect((try g.next()).? == 0);
    try expect((try g.next()).? == 1);
    try expect((try g.next()).? == 2);
    try expect(g.return_value == null);
    try expect((try g.next()) == null);
    try expect(g.state == .Done);
    try expect(g.return_value.? == 3);
}

test "drain" {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8)) !u8 {
            handle.yield(0);
            handle.yield(1);
            handle.yield(2);
            return 3;
        }
    };
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try expect((try g.drain()).* == 3);
    try expect(g.state == .Done);
    try expect(g.return_value.? == 3);
}
