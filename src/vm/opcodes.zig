pub const OpCode = enum(u8) {
    // Stack
    push_const = 0x01,
    push_null = 0x02,
    push_true = 0x03,
    push_false = 0x04,
    pop = 0x05,

    // Variables
    load_local = 0x10,
    store_local = 0x11,

    // Arithmetic
    add = 0x20,
    sub = 0x21,
    mul = 0x22,
    div = 0x23,
    mod = 0x24,
    neg = 0x25,

    // Comparison
    eq = 0x30,
    neq = 0x31,
    lt = 0x32,
    gt = 0x33,
    lte = 0x34,
    gte = 0x35,

    // Logic
    op_and = 0x40,
    op_or = 0x41,
    op_not = 0x42,

    // Control flow
    jump = 0x50,
    jump_if = 0x51,
    jump_if_not = 0x52,
    call = 0x53,
    ret = 0x54,

    // Data structures
    make_array = 0x60,
    make_map = 0x61,
    load_index = 0x62,
    store_index = 0x63,
    load_member = 0x64,
    store_member = 0x65,

    // Events (scenario layer)
    emit_text = 0x70,
    emit_speaker = 0x71,
    emit_wait = 0x72,
    emit_save_point = 0x73,
    emit_directive = 0x74,
    emit_choice = 0x75,
    emit_text_clear = 0x76,

    // Special
    halt = 0xFF,

    pub fn operandSize(self: OpCode) u8 {
        return switch (self) {
            .push_const, .load_local, .store_local,
            .make_array, .make_map,
            .load_member, .store_member,
            => 2,
            .jump, .jump_if, .jump_if_not => 4,
            .call => 3,
            .emit_wait => 4,
            .emit_directive => 2,
            .emit_choice => 1,
            else => 0,
        };
    }
};

test "opcode operand sizes" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u8, 2), OpCode.push_const.operandSize());
    try std.testing.expectEqual(@as(u8, 4), OpCode.jump.operandSize());
    try std.testing.expectEqual(@as(u8, 3), OpCode.call.operandSize());
    try std.testing.expectEqual(@as(u8, 0), OpCode.add.operandSize());
    try std.testing.expectEqual(@as(u8, 0), OpCode.halt.operandSize());
}
