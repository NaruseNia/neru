const std = @import("std");
const opcodes = @import("opcodes.zig");
const value = @import("value.zig");
const stack = @import("stack.zig");

pub const Value = value.Value;
pub const OpCode = opcodes.OpCode;

pub const VM = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VM {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VM) void {
        _ = self;
    }
};

test "VM stub" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
}
