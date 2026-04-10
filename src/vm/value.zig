const std = @import("std");

pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
    null_val: void,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .bool_val => |b| b,
            .null_val => false,
            .int => |i| i != 0,
            .float => |f| f != 0.0,
            .string => |s| s.len > 0,
        };
    }

    pub fn eql(self: Value, other: Value) bool {
        const self_tag: @typeInfo(Value).@"union".tag_type.? = self;
        const other_tag: @typeInfo(Value).@"union".tag_type.? = other;
        if (self_tag != other_tag) return false;

        return switch (self) {
            .int => |a| a == other.int,
            .float => |a| a == other.float,
            .string => |a| std.mem.eql(u8, a, other.string),
            .bool_val => |a| a == other.bool_val,
            .null_val => true,
        };
    }

    pub fn formatValue(self: Value, writer: anytype) !void {
        switch (self) {
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d:.6}", .{f}),
            .string => |s| try writer.print("{s}", .{s}),
            .bool_val => |b| try writer.print("{}", .{b}),
            .null_val => try writer.print("null", .{}),
        }
    }
};

test "Value.isTruthy" {
    const true_val = Value{ .bool_val = true };
    const false_val = Value{ .bool_val = false };
    const null_val = Value{ .null_val = {} };
    const int_val = Value{ .int = 42 };
    const zero_val = Value{ .int = 0 };

    try std.testing.expect(true_val.isTruthy());
    try std.testing.expect(!false_val.isTruthy());
    try std.testing.expect(!null_val.isTruthy());
    try std.testing.expect(int_val.isTruthy());
    try std.testing.expect(!zero_val.isTruthy());
}

test "Value.eql" {
    const a = Value{ .int = 42 };
    const b = Value{ .int = 42 };
    const c = Value{ .int = 43 };
    const null1 = Value{ .null_val = {} };
    const null2 = Value{ .null_val = {} };
    const zero = Value{ .int = 0 };
    const false_val = Value{ .bool_val = false };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(null1.eql(null2));
    try std.testing.expect(!zero.eql(false_val));
}
