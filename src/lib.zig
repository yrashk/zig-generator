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
//!     pub fn generate(_: *@This(), handle: *gen.Handle(u8, u8)) !u8 {
//!         try handle.yield(0);
//!         try handle.yield(1);
//!         try handle.yield(2);
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
//!     std.debug.assert(g.state.Returned == 3);
//! }
//! ```

const std = @import("std");
const assert = std.debug.assert;

pub const Cancellation = error{
    GeneratorCancelled,
};

pub const State = enum { Initialized, Started, Error, Returned };

fn StateUnion(comptime Return: type) type {
    return union(State) {
        Initialized: void,
        Started: void,
        Error: void,
        Returned: Return,
    };
}

/// Generator handle, to be used in Handle's Ctx type
///
/// `T` is the type that the generator yields
/// `Return` is generator's return type
pub fn Handle(comptime T: type, comptime Return: type) type {
    return struct {
        const Self = @This();

        const HandleState = enum { Working, Yielded, Cancel, Returned };

        frame: *@Frame(yield) = undefined,

        gen_state: *StateUnion(Return) = undefined,
        gen_frame: ?anyframe = null,

        state: union(HandleState) {
            Working: void,
            Yielded: T,
            Cancel: void,
            Returned: void,
        } = .Working,

        /// Yields a value
        pub fn yield(self: *Self, t: T) error{GeneratorCancelled}!void {
            if (self.state == .Cancel) return error.GeneratorCancelled;

            suspend {
                self.state = .{ .Yielded = t };
                self.frame = @frame();
                self.resumeGenerator();
            }
            if (self.state == .Cancel) return error.GeneratorCancelled;
            self.state = .Working;
        }

        /// Terminates the generator
        ///
        /// This approach is faster than returning from an async function, so
        /// if performance of finishing the generator is important, one should use this function
        /// instead of function return flow.
        ///
        /// NOTE: It is important to understand that if this approach is
        /// used, generator function's deferred code won't run.
        /// If deferred code is still desired in such situation, one workaround would be
        /// put generator's code in a block and call `finish` outside of that block (if feasible):
        /// ```
        /// pub fn generate(self: *Self, handle: *generator.Handle(u8, u8)) !u8 {
        ///     {
        ///       defer self.deinit();
        ///       try handle.yield(0);
        ///     }
        ///     handle.finish(1);
        ///     unreachable; // necessary until `finish` becomes `noreturn`
        /// }
        /// ```
        /// 
        /// Pending resolution of https://github.com/ziglang/zig/issues/5728 should get
        /// `noreturn` as a return type. For now it's just a promise it'll never return.
        pub fn finish(self: *Self, return_value: Return) void {
            suspend {
                self.gen_state.* = .{ .Returned = return_value };
                self.done();
            }
            unreachable;
        }

        fn done(self: *Self) void {
            self.state = .Returned;
            self.resumeGenerator();
        }

        fn resumeGenerator(self: *Self) void {
            if (self.gen_frame) |frame| {
                resume frame;
            }
        }
    };
}

/// Generator type allows an async function to yield multiple
/// values, and return an error or a result.
///
/// Ctx type must be a struct and it must have the following function:
///
/// * `generate(self: *@This(), handle: *generator.Handle(T, Return)) !Return`
///
/// where `T` is the type of value yielded by the generator and `Return` is
/// the type of the return value.
///
/// NOTE: In many cases it may be advisable to have `T` be a pointer to a type,
/// particularly if the the yielded type is larger than a machine word.
/// This will eliminate the unnecessary copying of the value and may have a positive
/// impact on performance.
/// This is also a critical consideration if the generator needs to be able to
/// observe changes that occurred to the value during suspension.
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
    const Ret = ret_tinfo.ErrorUnion.payload;
    assert(arg2_tinfo == .Pointer);
    assert(arg2_tinfo.Pointer.child == Handle(T, Ret));

    assert(ret_tinfo == .ErrorUnion);

    return struct {
        const Self = @This();
        const Err = ret_tinfo.ErrorUnion.error_set;
        const CompleteErrorSet = Err || Cancellation;

        pub const Return = ret_tinfo.ErrorUnion.payload;
        pub const Context = Ctx;

        handle: Handle(T, Return) = Handle(T, Return){},

        /// Generator's state
        /// 
        /// * `.Initialized` -- it hasn't been started yet
        /// * `.Started` -- it has been started
        /// * `.Returned` -- it has returned a value
        /// * `.Error` -- it has returned an error
        state: StateUnion(Return) = .Initialized,

        frame: @Frame(generator) = undefined,

        /// Generator's own structure
        context: Context,

        /// Initializes a generator
        pub fn init(ctx: Ctx) Self {
            return Self{
                .context = ctx,
            };
        }

        fn generator(self: *Self) CompleteErrorSet!Return {
            defer self.handle.done();

            return try generate_fn(&self.context, &self.handle);
        }

        fn awaitActionable(self: *Self) void {
            if (self.handle.state == .Working) {
                suspend {
                    self.handle.gen_frame = @frame();
                }
                std.debug.assert(self.handle.state != .Working);
                self.handle.gen_frame = null;
            }
        }

        /// Returns the next yielded value, or `null` if the generator has completed
        ///
        /// .state.Returned union variant can be used to retrieve the return value of the generator
        /// once it has completed.
        ///
        /// `next()` also propagates errors returned by the generator function.
        pub fn next(self: *Self) Err!?T {
            switch (self.state) {
                .Initialized => {
                    self.state = .Started;
                    self.handle.gen_state = &self.state;
                    self.frame = async self.generator();
                },
                .Started => {
                    resume self.handle.frame;
                },
                .Error => return null,
                .Returned => return null,
            }

            self.awaitActionable();

            if (self.handle.state == .Returned) {
                var err: ?Err = null;
                if (@as(State, self.state) != .Returned) {
                    self.state = .{ .Returned = await self.frame catch |err_| error_handler: {
                        switch (err_) {
                            error.GeneratorCancelled => {},
                            else => |e| err = e,
                        }
                        break :error_handler undefined;
                    } };
                }

                if (err) |e| {
                    self.state = .Error;
                    return e;
                }

                return null;
            }

            return self.handle.state.Yielded;
        }

        /// Drains the generator until it is done, returning a pointer to `self.state.Returned`
        pub fn drain(self: *Self) !*Return {
            while (try self.next()) |_| {}
            return &self.state.Returned;
        }

        /// Cancels the generator
        ///
        /// It won't yield any more values and will run its deferred code.
        /// 
        /// However, it may still continue working until it attempts to yield.
        /// This is possible if the generator is an async function using other async functions.
        ///
        /// NOTE that the generator must cooperate (or at least, not get in the way) with its cancellation.
        /// An uncooperative generator can catch `GeneratorCancelled` error and refuse to be terminated.
        /// In such case, the generator will be effectively drained upon an attempt to cancel it.
        pub fn cancel(self: *Self) void {
            self.handle.state = .Cancel;
        }
    };
}

test "basic generator" {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8, void)) !void {
            try handle.yield(0);
            try handle.yield(1);
            try handle.yield(2);
        }
    };
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try expect((try g.next()).? == 0);
    try expect((try g.next()).? == 1);
    try expect((try g.next()).? == 2);
    try expect((try g.next()) == null);
    try expect(g.state == .Returned);
    try expect((try g.next()) == null);
}

test "generator with async i/o" {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8, void)) !void {
            const file = try std.fs.cwd()
                .openFile("README.md", std.fs.File.OpenFlags{ .read = true, .write = false });
            const reader = file.reader();

            while (true) {
                const byte = reader.readByte() catch return;
                try handle.yield(byte);
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

test "generator with async await" {
    const expect = std.testing.expect;
    const ty = struct {
        fn doAsync() callconv(.Async) u8 {
            suspend {
                resume @frame();
            }
            return 1;
        }

        pub fn generate(_: *@This(), handle: *Handle(u8, void)) !void {
            try handle.yield(await async doAsync());
        }
    };
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try expect((try g.next()).? == 1);
}

test "context" {
    const expect = std.testing.expect;

    const ty = struct {
        a: u8 = 1,

        pub fn generate(_: *@This(), handle: *Handle(u8, void)) !void {
            try handle.yield(0);
            try handle.yield(1);
            try handle.yield(2);
        }
    };

    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try expect(g.context.a == 1);
}

test "errors in generators" {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8, void)) !void {
            try handle.yield(0);
            try handle.yield(1);
            return error.SomeError;
        }
    };
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try expect((try g.next()).? == 0);
    try expect((try g.next()).? == 1);
    _ = g.next() catch |err| {
        try expect(g.state == .Error);
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
        complete: bool = false,
        pub fn generate(self: *@This(), handle: *Handle(u8, u8)) !u8 {
            defer {
                self.complete = true;
            }
            try handle.yield(0);
            try handle.yield(1);
            try handle.yield(2);
            return 3;
        }
    };
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try expect((try g.next()).? == 0);
    try expect((try g.next()).? == 1);
    try expect((try g.next()).? == 2);
    try expect((try g.next()) == null);
    try expect(g.state == .Returned);
    try expect(g.state.Returned == 3);
    try expect(g.context.complete);
}

test "fast-path return value in generator (finish)" {
    const expect = std.testing.expect;
    const ty = struct {
        complete: bool = false,
        inner_complete: bool = false,

        pub fn generate(self: *@This(), handle: *Handle(u8, u8)) !u8 {
            defer {
                self.complete = true;
            }
            {
                defer {
                    self.inner_complete = true;
                }
                try handle.yield(0);
                try handle.yield(1);
                try handle.yield(2);
            }
            handle.finish(3);
            unreachable;
        }
    };
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try expect((try g.next()).? == 0);
    try expect((try g.next()).? == 1);
    try expect((try g.next()).? == 2);
    try expect((try g.next()) == null);
    try expect(g.state == .Returned);
    try expect(g.state.Returned == 3);

    try expect(!g.context.complete);
    try expect(g.context.inner_complete);
}

test "drain" {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8, u8)) !u8 {
            try handle.yield(0);
            try handle.yield(1);
            try handle.yield(2);
            return 3;
        }
    };
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try expect((try g.drain()).* == 3);
    try expect(g.state == .Returned);
    try expect(g.state.Returned == 3);
}

test "cancel" {
    const expect = std.testing.expect;
    const ty = struct {
        drained: bool = false,
        cancelled: bool = false,

        pub fn generate(self: *@This(), handle: *Handle(u8, u8)) !u8 {
            errdefer |e| {
                if (e == error.GeneratorCancelled) {
                    self.cancelled = true;
                }
            }
            try handle.yield(0);
            try handle.yield(1);
            try handle.yield(2);
            self.drained = true;
            return 3;
        }
    };

    const G = Generator(ty, u8);

    // cancel before yielding
    var g = G.init(ty{});
    g.cancel();
    try expect((try g.next()) == null);
    try expect(g.state == .Returned);
    try expect(!g.context.drained);
    try expect(g.context.cancelled);

    // cancel after yielding
    g = G.init(ty{});
    try expect((try g.next()).? == 0);
    g.cancel();
    try expect((try g.next()) == null);
    try expect(g.state == .Returned);
    try expect(!g.context.drained);
    try expect(g.context.cancelled);
}

test "uncooperative cancellation" {
    const expect = std.testing.expect;
    const ty = struct {
        drained: bool = false,
        ignored_termination_0: bool = false,
        ignored_termination_1: bool = false,

        pub fn generate(self: *@This(), handle: *Handle(u8, void)) !void {
            handle.yield(0) catch {
                self.ignored_termination_0 = true;
            };
            handle.yield(1) catch {
                self.ignored_termination_1 = true;
            };
            self.drained = true;
        }
    };

    const G = Generator(ty, u8);

    // Cancel before yielding
    var g = G.init(ty{});
    g.cancel();
    try expect((try g.next()) == null);
    try expect(g.state == .Returned);
    try expect(g.context.drained);
    try expect(g.context.ignored_termination_0);
    try expect(g.context.ignored_termination_1);

    // Cancel after yielding
    g = G.init(ty{});
    try expect((try g.next()).? == 0);
    g.cancel();
    try expect((try g.next()) == null);
    try expect(g.state == .Returned);
    try expect(g.context.drained);
    try expect(g.context.ignored_termination_0);
    try expect(g.context.ignored_termination_1);
}
