// Re-export primary types for clean API: neru.vm.VM, neru.vm.Value, etc.
pub const VM = core.VM;
pub const VMError = core.VMError;
pub const CallFrame = core.CallFrame;
pub const Value = value.Value;
pub const OpCode = opcodes.OpCode;

// Sub-modules for detailed access
pub const core = @import("vm/vm.zig");
pub const opcodes = @import("vm/opcodes.zig");
pub const value = @import("vm/value.zig");
pub const stack = @import("vm/stack.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
