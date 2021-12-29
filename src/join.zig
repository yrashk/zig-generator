const std = @import("std");
const generator = @import("./generator.zig");

// pending resolution of https://github.com/ziglang/zig/issues/10442,
// this has to be a function separate from `Join`
fn joinedGenerator(comptime g: type, comptime T: type) type {
    return struct {
        generator: g,
        state: enum { Next, Awaiting, Returned, Done } = .Next,
        frame: @Frame(next) = undefined,
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

/// Joins multiple generators into one and yields values as they come from
/// either generator
pub fn Join(comptime generators: []const type, comptime T: type) type {
    var generator_fields: [generators.len]std.builtin.TypeInfo.StructField = undefined;
    inline for (generators) |g, field_index| {
        const G = joinedGenerator(g, T);
        generator_fields[field_index] = .{
            .name = std.fmt.comptimePrint("{d}:{s}", .{ field_index, @typeName(g) }),
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

    const init_tuple = std.meta.Tuple(generators);

    return generator.Generator(struct {
        const Self = @This();

        generators: @Type(generators_struct) = undefined,
        frame: *@Frame(generate) = undefined,

        pub fn init(g: init_tuple) Self {
            var s = Self{};
            inline for (generator_fields_const) |field, i| {
                s.generators[i] = .{ .generator = g[i] };
                _ = field;
                _ = i;
                _ = g;
            }
            return s;
        }

        pub fn generate(self: *Self, handle: *generator.Handle(T)) !void {
            _ = self;
            _ = handle;
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
    const G = Join(&[_]type{ G0, G1 }, u8);
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
    const G = Join(&[_]type{ G0, G0 }, u8);
    var g = G.init(G.Context.init(.{ G0.init(ty{}), G0.init(ty{}) }));

    // test
    var size: usize = 0;
    while (try g.next()) |_| {
        size += 1;
    }

    try expect(size == file_size * 2);
}
