pub const compiler = @import("compiler.zig");
pub const vm = @import("vm.zig");
pub const runtime = @import("runtime.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
