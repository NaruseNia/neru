pub const opcodes = @import("vm/opcodes.zig");
pub const value = @import("vm/value.zig");
pub const stack = @import("vm/stack.zig");
pub const vm = @import("vm/vm.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
