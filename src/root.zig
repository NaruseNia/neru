pub const compiler = @import("compiler.zig");
pub const vm = @import("vm.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
