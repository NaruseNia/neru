pub fn Stack(comptime T: type, comptime max_size: usize) type {
    return struct {
        const Self = @This();

        items: [max_size]T = undefined,
        top: usize = 0,

        pub const Error = error{
            StackOverflow,
            StackUnderflow,
        };

        pub fn push(self: *Self, value: T) Error!void {
            if (self.top >= max_size) return error.StackOverflow;
            self.items[self.top] = value;
            self.top += 1;
        }

        pub fn pop(self: *Self) Error!T {
            if (self.top == 0) return error.StackUnderflow;
            self.top -= 1;
            return self.items[self.top];
        }

        pub fn peek(self: *const Self) Error!T {
            if (self.top == 0) return error.StackUnderflow;
            return self.items[self.top - 1];
        }

        pub fn peekAt(self: *const Self, distance: usize) Error!T {
            if (distance >= self.top) return error.StackUnderflow;
            return self.items[self.top - 1 - distance];
        }

        pub fn get(self: *const Self, index: usize) T {
            return self.items[index];
        }

        pub fn set(self: *Self, index: usize, value: T) void {
            self.items[index] = value;
        }

        pub fn len(self: *const Self) usize {
            return self.top;
        }

        pub fn reset(self: *Self) void {
            self.top = 0;
        }
    };
}

test "Stack push and pop" {
    const std = @import("std");
    var stack: Stack(i32, 16) = .{};

    try stack.push(10);
    try stack.push(20);
    try stack.push(30);

    try std.testing.expectEqual(@as(usize, 3), stack.len());
    try std.testing.expectEqual(@as(i32, 30), try stack.pop());
    try std.testing.expectEqual(@as(i32, 20), try stack.pop());
    try std.testing.expectEqual(@as(i32, 10), try stack.pop());
    try std.testing.expectEqual(@as(usize, 0), stack.len());
}

test "Stack overflow" {
    var stack: Stack(i32, 2) = .{};
    try stack.push(1);
    try stack.push(2);

    const result = stack.push(3);
    if (result) |_| {
        @panic("expected overflow error");
    } else |err| {
        const std = @import("std");
        try std.testing.expectEqual(error.StackOverflow, err);
    }
}

test "Stack underflow" {
    var stack: Stack(i32, 2) = .{};
    const result = stack.pop();
    if (result) |_| {
        @panic("expected underflow error");
    } else |err| {
        const std = @import("std");
        try std.testing.expectEqual(error.StackUnderflow, err);
    }
}

test "Stack peek and peekAt" {
    const std = @import("std");
    var stack: Stack(i32, 16) = .{};
    try stack.push(10);
    try stack.push(20);

    try std.testing.expectEqual(@as(i32, 20), try stack.peek());
    try std.testing.expectEqual(@as(i32, 20), try stack.peekAt(0));
    try std.testing.expectEqual(@as(i32, 10), try stack.peekAt(1));
}

test "Stack get and set" {
    const std = @import("std");
    var stack: Stack(i32, 16) = .{};
    try stack.push(10);
    try stack.push(20);

    try std.testing.expectEqual(@as(i32, 10), stack.get(0));
    stack.set(0, 99);
    try std.testing.expectEqual(@as(i32, 99), stack.get(0));
}
