const std = @import("std");
const generator = @import("./generator.zig");

// pending resolution of https://github.com/ziglang/zig/issues/10442,
// this has to be a function separate from `Join`
fn joinedGenerator(comptime g: type, comptime T: type, comptime allocating: bool) type {
    return struct {
        generator: g,
        state: enum { Next, Awaiting, Returned, Done } = .Next,
        frame: if (allocating) *@Frame(next) else @Frame(next) = undefined,
        fn next(self: *@This(), counter: *std.atomic.Atomic(usize), frame: anyframe) !?T {
            defer {
                self.state = .Returned;
                if (counter.fetchAdd(1, .SeqCst) == 0) {
                    resume frame;
                }
            }
            return self.generator.next();
        }
    };
}

fn initializer(
    comptime Self: type,
    comptime generators: []const type,
    generator_fields: []const std.builtin.TypeInfo.StructField,
    comptime allocating: bool,
) type {
    return if (allocating) struct {
        pub fn init(g: std.meta.Tuple(generators), allocator: std.mem.Allocator) Self {
            var s = Self{ .allocator = allocator };
            inline for (generator_fields) |_, i| {
                s.generators[i] = .{ .generator = g[i] };
            }
            return s;
        }
    } else struct {
        pub fn init(g: std.meta.Tuple(generators)) Self {
            var s = Self{};
            inline for (generator_fields) |_, i| {
                s.generators[i] = .{ .generator = g[i] };
            }
            return s;
        }
    };
}

/// Joins multiple generators into one and yields values as they come from
/// either generator
pub fn Join(comptime generators: []const type, comptime T: type, comptime allocating: bool) type {
    var generator_fields: [generators.len]std.builtin.TypeInfo.StructField = undefined;
    inline for (generators) |g, field_index| {
        const G = joinedGenerator(g, T, allocating);
        generator_fields[field_index] = .{
            .name = std.fmt.comptimePrint("{d}", .{field_index}),
            .field_type = G,
            .default_value = @as(?G, null),
            .is_comptime = false,
            .alignment = @alignOf(G),
        };
    }
    const generators_struct = std.builtin.TypeInfo{
        .Struct = .{
            .layout = .Auto,
            .fields = &generator_fields,
            .decls = &[0]std.builtin.TypeInfo.Declaration{},
            .is_tuple = true,
        },
    };

    const generator_fields_const = generator_fields;

    return generator.Generator(struct {
        const Self = @This();

        generators: @Type(generators_struct) = undefined,
        frame: *@Frame(generate) = undefined,
        allocator: if (allocating) std.mem.Allocator else void = undefined,

        pub usingnamespace initializer(Self, generators, &generator_fields_const, allocating);

        pub fn generate(self: *Self, handle: *generator.Handle(T)) !void {
            if (allocating) {
                inline for (generator_fields_const) |_, i| {
                    var g = &self.generators[i];
                    g.frame = self.allocator.create(@Frame(@TypeOf(g.*).next)) catch |e| {
                        @setEvalBranchQuota(generators.len * 1000);
                        inline for (generator_fields_const) |_, i_| {
                            if (i_ == i) return e;
                            var g_ = &self.generators[i_];
                            self.allocator.destroy(g_.frame);
                        }
                    };
                }
            }

            defer {
                if (allocating) {
                    inline for (generator_fields_const) |_, i| {
                        var g = &self.generators[i];
                        if (g.state != .Done)
                            self.allocator.destroy(g.frame);
                    }
                }
            }

            var counter = std.atomic.Atomic(usize).init(0);
            var active: usize = self.generators.len;
            var reported: usize = 0;
            while (true) {
                // If there are no new reports, suspend until resumed by one
                suspend {
                    if (counter.swap(0, .SeqCst) == reported) {
                        // run next() where needed
                        inline for (generator_fields_const) |_, i| {
                            var g = &self.generators[i];
                            if (g.state == .Next) {
                                g.state = .Awaiting;
                                if (allocating)
                                    g.frame.* = async g.next(&counter, @frame())
                                else
                                    g.frame = async g.next(&counter, @frame());
                            }
                        }
                    } else {
                        reported = 0;
                        resume @frame();
                    }
                }
                reported = counter.load(.SeqCst);

                while (true) {
                    // check for returns
                    var yielded: usize = 0;
                    inline for (generator_fields_const) |_, i| {
                        var g = &self.generators[i];
                        if (g.state == .Returned) {
                            yielded += 1;
                            const value = try await g.frame;
                            if (value) |v| {
                                try handle.yield(v);
                                g.state = .Next;
                            } else {
                                if (allocating)
                                    self.allocator.destroy(g.frame);
                                g.state = .Done;
                                active -= 1;
                            }
                        }
                    }
                    // ...until we run out of reports
                    if (yielded == 0) break;
                }
                if (active == 0) break;
            }
        }
    }, T);
}

test "basic" {
    const expect = std.testing.expect;
    const ty = struct {
        pub fn generate(_: *@This(), handle: *generator.Handle(u8)) !void {
            try handle.yield(1);
            try handle.yield(2);
            try handle.yield(3);
        }
    };
    const ty1 = struct {
        pub fn generate(_: *@This(), handle: *generator.Handle(u8)) !void {
            try handle.yield(10);
            try handle.yield(20);
            try handle.yield(30);
        }
    };

    const G0 = generator.Generator(ty, u8);
    const G1 = generator.Generator(ty1, u8);
    const G = Join(&[_]type{ G0, G1 }, u8, false);
    var g = G.init(G.Context.init(.{ G0.init(ty{}), G1.init(ty1{}) }));

    var sum: usize = 0;
    while (try g.next()) |v| {
        sum += v;
    }
    try expect(sum == 66);
}

test "with async i/o" {
    // determine file size
    const test_file = try std.fs.cwd()
        .openFile("README.md", std.fs.File.OpenFlags{ .read = true, .write = false });
    const test_reader = test_file.reader();

    var file_size: usize = 0;

    while (true) {
        _ = test_reader.readByte() catch break;
        file_size += 1;
    }

    const expect = std.testing.expect;

    // prepare reader type
    const ty = struct {
        pub fn generate(_: *@This(), handle: *generator.Handle(u8)) !void {
            const file = try std.fs.cwd()
                .openFile("README.md", std.fs.File.OpenFlags{ .read = true, .write = false });
            const reader = file.reader();

            while (true) {
                const byte = reader.readByte() catch return;
                try handle.yield(byte);
            }
        }
    };
    const G0 = generator.Generator(ty, u8);
    const G = Join(&[_]type{ G0, G0 }, u8, false);
    var g = G.init(G.Context.init(.{ G0.init(ty{}), G0.init(ty{}) }));

    // test
    var size: usize = 0;
    while (try g.next()) |_| {
        size += 1;
    }

    try expect(size == file_size * 2);
}

test "memory impact of not allocating vs allocating frames" {
    const ty = struct {
        pub fn generate(_: *@This(), handle: *generator.Handle(u8)) !void {
            try handle.yield(1);
            try handle.yield(2);
            try handle.yield(3);
        }
    };
    const G0 = generator.Generator(ty, u8);
    const GAllocating = Join(&[_]type{G0} ** 50, u8, true);
    const GNonAllocating = Join(&[_]type{G0} ** 50, u8, false);

    _ = GNonAllocating.init(GNonAllocating.Context.init(.{G0.init(ty{})}));
    _ = GAllocating.init(GAllocating.Context.init(.{G0.init(ty{})}, std.testing.allocator));

    // The assertion below doesn't hold true for all number of joined generators
    // as the frame of the allocating Join generator can get larger than of the non-allocating one.
    // Could be related to this:
    // https://zigforum.org/t/unacceptable-memory-overhead-with-nested-async-function-call/407/5

    //    try std.testing.expect(@sizeOf(GAllocating) < @sizeOf(GNonAllocating));
}

test "allocating join" {
    const expect = std.testing.expect;

    const ty = struct {
        pub fn generate(_: *@This(), handle: *generator.Handle(u8)) !void {
            try handle.yield(1);
            try handle.yield(2);
            try handle.yield(3);
        }
    };
    const G0 = generator.Generator(ty, u8);
    const G = Join(&[_]type{G0}, u8, true);

    var g = G.init(G.Context.init(.{G0.init(ty{})}, std.testing.allocator));

    try expect((try g.next()).? == 1);
    try expect((try g.next()).? == 2);
    try expect((try g.next()).? == 3);
    try expect((try g.next()) == null);
}
