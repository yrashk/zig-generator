const std = @import("std");
const assert = std.debug.assert;

pub const Cancellation = error{
    GeneratorCancelled,
};

pub const State = enum { Initialized, Started, Error, Returned, Cancelled };

/// Generator handle, to be used in Handle's Ctx type
///
/// `T` is the type that the generator yields
/// `Return` is generator's return type
pub fn Handle(comptime T: type) type {
    return struct {
        const Self = @This();

        const HandleState = enum { Working, Yielded, Cancel };

        const Suspension = enum(u8) { Unsuspended, Suspended, Yielded };

        frame: *@Frame(yield) = undefined,
        gen_frame: anyframe = undefined,
        gen_frame_suspended: std.atomic.Atomic(Suspension) = std.atomic.Atomic(Suspension).init(.Unsuspended),

        state: union(HandleState) {
            Working: void,
            Yielded: T,
            Cancel: void,
        } = .Working,

        /// Yields a value
        pub fn yield(self: *Self, t: T) error{GeneratorCancelled}!void {
            if (self.state == .Cancel) return error.GeneratorCancelled;

            suspend {
                self.state = .{ .Yielded = t };
                self.frame = @frame();
                if (self.gen_frame_suspended.swap(.Yielded, .SeqCst) == .Suspended) {
                    resume self.gen_frame;
                }
            }
            if (self.state == .Cancel) return error.GeneratorCancelled;
            self.state = .Working;
        }
    };
}

/// Generator type allows an async function to yield multiple
/// values, and return an error or a result.
///
/// Ctx type must be a struct and it must have the following function:
///
/// * `generate(self: *@This(), handle: *generator.Handle(T)) !Return`
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
    assert(arg2_tinfo == .Pointer);
    assert(arg2_tinfo.Pointer.child == Handle(T));

    assert(ret_tinfo == .ErrorUnion);

    return struct {
        const Self = @This();
        const Err = ret_tinfo.ErrorUnion.error_set;
        const CompleteErrorSet = Err || Cancellation;

        pub const Return = ret_tinfo.ErrorUnion.payload;
        pub const Context = Ctx;
        pub const GeneratorState = union(State) {
            Initialized: void,
            Started: void,
            Error: Err,
            Returned: Return,
            Cancelled: void,
        };

        handle: Handle(T) = Handle(T){},

        /// Generator's state
        /// 
        /// * `.Initialized` -- it hasn't been started yet
        /// * `.Started` -- it has been started
        /// * `.Returned` -- it has returned a value
        /// * `.Error` -- it has returned an error
        /// * `.Cancelled` -- it has been cancelled
        state: GeneratorState = .Initialized,

        /// Generator's own structure
        context: Context,

        /// Initializes a generator
        pub fn init(ctx: Ctx) Self {
            return Self{
                .context = ctx,
            };
        }

        fn generator(self: *Self) void {
            if (generate_fn(&self.context, &self.handle)) |val| {
                self.state = .{ .Returned = val };
            } else |err| {
                switch (err) {
                    error.GeneratorCancelled => {
                        self.state = .Cancelled;
                    },
                    else => |e| {
                        self.state = .{ .Error = e };
                    },
                }
            }
            if (self.handle.gen_frame_suspended.load(.SeqCst) == .Suspended) {
                resume self.handle.gen_frame;
            }

            suspend {}
            unreachable;
        }

        /// Returns the next yielded value, or `null` if the generator returned or was cancelled.
        /// `next()` propagates errors returned by the generator function.
        ///
        /// .state.Returned union variant can be used to retrieve the return value of the generator
        /// .state.Cancelled indicates that the generator was cancelled
        /// .state.Error union variant can be used to retrieve the error
        ///
        pub fn next(self: *Self) Err!?T {
            switch (self.state) {
                .Initialized => {
                    self.state = .Started;
                    self.handle.gen_frame = @frame();
                    _ = async self.generator();
                },
                .Started => {
                    resume self.handle.frame;
                },
                else => return null,
            }

            while (self.state == .Started and self.handle.state == .Working) {
                suspend {
                    if (self.handle.gen_frame_suspended.swap(.Suspended, .SeqCst) == .Yielded) {
                        resume @frame();
                    }
                }
                self.handle.gen_frame_suspended.store(.Unsuspended, .SeqCst);
            }

            switch (self.state) {
                .Started => {
                    return self.handle.state.Yielded;
                },
                .Error => |e| return e,
                else => return null,
            }
        }

        /// Drains the generator until it is done
        pub fn drain(self: *Self) !void {
            while (try self.next()) |_| {}
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
        pub fn generate(_: *@This(), handle: *Handle(u8)) !void {
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
        pub fn generate(_: *@This(), handle: *Handle(u8)) !void {
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

        pub fn generate(_: *@This(), handle: *Handle(u8)) !void {
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

        pub fn generate(_: *@This(), handle: *Handle(u8)) !void {
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
        pub fn generate(_: *@This(), handle: *Handle(u8)) !void {
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
        pub fn generate(self: *@This(), handle: *Handle(u8)) !u8 {
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

test "drain" {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *Handle(u8)) !u8 {
            try handle.yield(0);
            try handle.yield(1);
            try handle.yield(2);
            return 3;
        }
    };
    const G = Generator(ty, u8);
    var g = G.init(ty{});

    try g.drain();
    try expect(g.state.Returned == 3);
}

test "cancel" {
    const expect = std.testing.expect;
    const ty = struct {
        drained: bool = false,
        cancelled: bool = false,

        pub fn generate(self: *@This(), handle: *Handle(u8)) !u8 {
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
    try expect(g.state == .Cancelled);
    try expect(!g.context.drained);
    try expect(g.context.cancelled);

    // cancel after yielding
    g = G.init(ty{});
    try expect((try g.next()).? == 0);
    g.cancel();
    try expect((try g.next()) == null);
    try expect(g.state == .Cancelled);
    try expect(!g.context.drained);
    try expect(g.context.cancelled);
}

test "uncooperative cancellation" {
    const expect = std.testing.expect;
    const ty = struct {
        drained: bool = false,
        ignored_termination_0: bool = false,
        ignored_termination_1: bool = false,

        pub fn generate(self: *@This(), handle: *Handle(u8)) !void {
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
