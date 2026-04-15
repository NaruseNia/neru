const std = @import("std");

/// Heap-allocated array storage, owned by the VM.
pub const ArrayHandle = struct {
    items: std.ArrayListUnmanaged(Value) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ArrayHandle {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ArrayHandle) void {
        self.items.deinit(self.allocator);
    }
};

/// Heap-allocated map storage (string keys), owned by the VM.
pub const MapHandle = struct {
    entries: std.StringArrayHashMapUnmanaged(Value) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MapHandle {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MapHandle) void {
        self.entries.deinit(self.allocator);
    }
};

/// Heap-allocated closure storage: a function reference + captured upvalues.
pub const ClosureHandle = struct {
    function_id: u16,
    upvalues: []Value,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, function_id: u16, upvalue_count: u16) !*ClosureHandle {
        const upvalues = try allocator.alloc(Value, upvalue_count);
        @memset(upvalues, Value{ .null_val = {} });
        const handle = try allocator.create(ClosureHandle);
        handle.* = .{
            .function_id = function_id,
            .upvalues = upvalues,
            .allocator = allocator,
        };
        return handle;
    }

    pub fn deinit(self: *ClosureHandle) void {
        self.allocator.free(self.upvalues);
    }
};

pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
    null_val: void,
    function: u16, // function table index
    closure: *ClosureHandle, // function + captured upvalues
    array: *ArrayHandle,
    map: *MapHandle,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .bool_val => |b| b,
            .null_val => false,
            .int => |i| i != 0,
            .float => |f| f != 0.0,
            .string => |s| s.len > 0,
            .function, .closure => true,
            .array => true,
            .map => true,
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
            .function => |a| a == other.function,
            .closure => |a| a == other.closure,
            // Reference equality for arrays and maps
            .array => |a| a == other.array,
            .map => |a| a == other.map,
        };
    }

    pub fn formatValue(self: Value, writer: anytype) !void {
        switch (self) {
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d:.6}", .{f}),
            .string => |s| try writer.print("{s}", .{s}),
            .bool_val => |b| try writer.print("{}", .{b}),
            .null_val => try writer.print("null", .{}),
            .function => |id| try writer.print("<fn:{d}>", .{id}),
            .closure => |c| try writer.print("<closure:fn:{d}>", .{c.function_id}),
            .array => |arr| {
                try writer.print("[", .{});
                for (arr.items.items, 0..) |item, idx| {
                    if (idx > 0) try writer.print(", ", .{});
                    try item.formatValue(writer);
                }
                try writer.print("]", .{});
            },
            .map => |m| {
                try writer.print("{{", .{});
                var it = m.entries.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try writer.print(", ", .{});
                    first = false;
                    try writer.print("\"{s}\": ", .{entry.key_ptr.*});
                    try entry.value_ptr.formatValue(writer);
                }
                try writer.print("}}", .{});
            },
        }
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .int => "int",
            .float => "float",
            .string => "string",
            .bool_val => "bool",
            .null_val => "null",
            .function, .closure => "function",
            .array => "array",
            .map => "map",
        };
    }
};

// Arithmetic helpers for the VM
pub fn add(a: Value, b: Value) !Value {
    return switch (a) {
        .int => |ai| switch (b) {
            .int => |bi| .{ .int = ai + bi },
            .float => |bf| .{ .float = @as(f64, @floatFromInt(ai)) + bf },
            else => error.TypeError,
        },
        .float => |af| switch (b) {
            .int => |bi| .{ .float = af + @as(f64, @floatFromInt(bi)) },
            .float => |bf| .{ .float = af + bf },
            else => error.TypeError,
        },
        .string => |as_str| switch (b) {
            .string => |bs| blk: {
                _ = as_str;
                _ = bs;
                // String concat requires allocation — handled by VM
                break :blk error.StringConcat;
            },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

pub fn sub(a: Value, b: Value) !Value {
    return switch (a) {
        .int => |ai| switch (b) {
            .int => |bi| .{ .int = ai - bi },
            .float => |bf| .{ .float = @as(f64, @floatFromInt(ai)) - bf },
            else => error.TypeError,
        },
        .float => |af| switch (b) {
            .int => |bi| .{ .float = af - @as(f64, @floatFromInt(bi)) },
            .float => |bf| .{ .float = af - bf },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

pub fn mul(a: Value, b: Value) !Value {
    return switch (a) {
        .int => |ai| switch (b) {
            .int => |bi| .{ .int = ai * bi },
            .float => |bf| .{ .float = @as(f64, @floatFromInt(ai)) * bf },
            else => error.TypeError,
        },
        .float => |af| switch (b) {
            .int => |bi| .{ .float = af * @as(f64, @floatFromInt(bi)) },
            .float => |bf| .{ .float = af * bf },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

pub fn div(a: Value, b: Value) !Value {
    return switch (a) {
        .int => |ai| switch (b) {
            .int => |bi| blk: {
                if (bi == 0) break :blk error.DivisionByZero;
                break :blk Value{ .int = @divTrunc(ai, bi) };
            },
            .float => |bf| blk: {
                if (bf == 0.0) break :blk error.DivisionByZero;
                break :blk Value{ .float = @as(f64, @floatFromInt(ai)) / bf };
            },
            else => error.TypeError,
        },
        .float => |af| switch (b) {
            .int => |bi| blk: {
                if (bi == 0) break :blk error.DivisionByZero;
                break :blk Value{ .float = af / @as(f64, @floatFromInt(bi)) };
            },
            .float => |bf| blk: {
                if (bf == 0.0) break :blk error.DivisionByZero;
                break :blk Value{ .float = af / bf };
            },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

pub fn mod_op(a: Value, b: Value) !Value {
    return switch (a) {
        .int => |ai| switch (b) {
            .int => |bi| blk: {
                if (bi == 0) break :blk error.DivisionByZero;
                break :blk Value{ .int = @mod(ai, bi) };
            },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

pub fn negate(a: Value) !Value {
    return switch (a) {
        .int => |i| .{ .int = -i },
        .float => |f| .{ .float = -f },
        else => error.TypeError,
    };
}

pub fn compare(a: Value, b: Value, op: enum { lt, gt, lte, gte }) !Value {
    const ord = switch (a) {
        .int => |ai| switch (b) {
            .int => |bi| std.math.order(ai, bi),
            .float => |bf| std.math.order(@as(f64, @floatFromInt(ai)), bf),
            else => return error.TypeError,
        },
        .float => |af| switch (b) {
            .int => |bi| std.math.order(af, @as(f64, @floatFromInt(bi))),
            .float => |bf| std.math.order(af, bf),
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
    const result = switch (op) {
        .lt => ord == .lt,
        .gt => ord == .gt,
        .lte => ord != .gt,
        .gte => ord != .lt,
    };
    return .{ .bool_val = result };
}

pub const ArithError = error{
    TypeError,
    DivisionByZero,
    StringConcat,
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

test "arithmetic operations" {
    const v5 = Value{ .int = 5 };
    const v3 = Value{ .int = 3 };
    const vf2 = Value{ .float = 2.0 };

    const sum = try add(v5, v3);
    try std.testing.expectEqual(@as(i64, 8), sum.int);

    const mixed = try add(v5, vf2);
    try std.testing.expectEqual(@as(f64, 7.0), mixed.float);

    const diff = try sub(v5, v3);
    try std.testing.expectEqual(@as(i64, 2), diff.int);

    const prod = try mul(v5, v3);
    try std.testing.expectEqual(@as(i64, 15), prod.int);

    const quot = try div(v5, v3);
    try std.testing.expectEqual(@as(i64, 1), quot.int);

    const neg = try negate(v5);
    try std.testing.expectEqual(@as(i64, -5), neg.int);
}

test "comparison operations" {
    const v5 = Value{ .int = 5 };
    const v3 = Value{ .int = 3 };

    const lt_result = try compare(v3, v5, .lt);
    try std.testing.expect(lt_result.bool_val);

    const gt_result = try compare(v5, v3, .gt);
    try std.testing.expect(gt_result.bool_val);

    const lte_result = try compare(v5, v5, .lte);
    try std.testing.expect(lte_result.bool_val);
}

test "division by zero" {
    const dv5 = Value{ .int = 5 };
    const v0 = Value{ .int = 0 };

    const result = div(dv5, v0);
    try std.testing.expectError(error.DivisionByZero, result);
}
