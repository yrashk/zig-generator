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

pub usingnamespace @import("./generator.zig");

pub const Join = @import("./join.zig").Select;
pub const Map = @import("./map.zig").Map;
