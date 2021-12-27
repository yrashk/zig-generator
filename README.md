# Zig Generator

This library provides a way to write generators in Zig.

Features:

* Supports async generator functions
* Propagates generator errors
* Return value capture

## Usage

Here's an example of its basic usage:

```zig
const std = @import("std");
const gen = @import("generator");

const Ty = struct {
    pub fn generate(_: *@This(), handle: *gen.Handle(u8, u8)) !u8 {
        try handle.yield(0);
        try handle.yield(1);
        try handle.yield(2);
        return 3;
    }
};

const G = gen.Generator(Ty, u8);

pub const io_mode = .evented;

pub fn main() !void {
    var g = G.init(Ty{});

    std.debug.assert((try g.next()).? == 0);
    std.debug.assert((try g.next()).? == 1);
    std.debug.assert((try g.next()).? == 2);
    std.debug.assert((try g.next()) == null);
    std.debug.assert(g.return_value().*.? == 3);
}
```

