const std = @import("std");

/// Internal use:
///
/// Finds and extracts any function in a given struct `T`
/// that has a type `Sig`
pub fn extractFn(comptime T: type, comptime Sig: type) Sig {
    switch (@typeInfo(T)) {
        .Struct => {
            const decls = std.meta.declarations(T);
            inline for (decls) |decl| {
                if (decl.is_pub) {
                    switch (decl.data) {
                        .Fn => |fn_decl| {
                            if (fn_decl.fn_type == Sig) {
                                return @field(T, decl.name);
                            }
                        },
                        else => {},
                    }
                }
            }
            @compileError("no public functions found");
        },
        else => @compileError("only structs are allowed"),
    }
}

test "extractFn" {
    const f = extractFn(struct {
        pub fn check(_: u8, _: u8) void {}
        pub fn add(a: u8, b: u8) u8 {
            return a + b;
        }
    }, fn (u8, u8) u8);
    try std.testing.expect(f(1, 2) == 3);
}
