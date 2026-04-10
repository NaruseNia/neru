const std = @import("std");
const opcodes_mod = @import("opcodes.zig");
const value_mod = @import("value.zig");
const stack_mod = @import("stack.zig");
const codegen = @import("../compiler/codegen.zig");

const OpCode = opcodes_mod.OpCode;
const Value = value_mod.Value;
const CompiledModule = codegen.CompiledModule;
const Constant = codegen.Constant;
const FunctionEntry = codegen.FunctionEntry;
const DebugLine = codegen.DebugLine;

const STACK_MAX = 1024;
const CALL_STACK_MAX = 256;

pub const CallFrame = struct {
    function_id: u16,
    return_ip: u32,
    base_pointer: u32,
    local_count: u16,
};

pub const VMError = error{
    StackOverflow,
    StackUnderflow,
    TypeError,
    DivisionByZero,
    UndefinedVariable,
    InvalidOpcode,
    InvalidFunction,
    ArityMismatch,
    RuntimeError,
    StringConcat,
};

pub const VM = struct {
    ip: u32,
    bytecode: []const u8,
    stack: stack_mod.Stack(Value, STACK_MAX),
    call_stack: stack_mod.Stack(CallFrame, CALL_STACK_MAX),

    constants: []const Constant,
    functions: []const FunctionEntry,
    debug_lines: []const DebugLine,

    allocator: std.mem.Allocator,

    // Strings allocated during execution
    allocated_strings: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) VM {
        return .{
            .ip = 0,
            .bytecode = &.{},
            .stack = .{},
            .call_stack = .{},
            .constants = &.{},
            .functions = &.{},
            .debug_lines = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VM) void {
        for (self.allocated_strings.items) |s| self.allocator.free(s);
        self.allocated_strings.deinit(self.allocator);
    }

    pub fn load(self: *VM, module: CompiledModule) void {
        self.bytecode = module.bytecode;
        self.constants = module.constants;
        self.functions = module.functions;
        self.debug_lines = module.debug_lines;

        // Start at main function (function 0)
        if (self.functions.len > 0) {
            self.ip = self.functions[0].bytecode_offset;
            // Reserve stack space for main's locals
            const main_locals = self.functions[0].local_count;
            var i: u16 = 0;
            while (i < main_locals) : (i += 1) {
                self.stack.push(.{ .null_val = {} }) catch break;
            }
        }
    }

    pub fn execute(self: *VM) VMError!?Value {
        return self.run();
    }

    fn run(self: *VM) VMError!?Value {
        while (self.ip < self.bytecode.len) {
            const op: OpCode = @enumFromInt(self.bytecode[self.ip]);
            self.ip += 1;

            switch (op) {
                .push_const => {
                    const idx = self.readU16();
                    const constant = self.constants[idx];
                    const val: Value = switch (constant) {
                        .int => |v| .{ .int = v },
                        .float => |v| .{ .float = v },
                        .string => |v| .{ .string = v },
                    };
                    try self.push(val);
                },
                .push_null => try self.push(.{ .null_val = {} }),
                .push_true => try self.push(.{ .bool_val = true }),
                .push_false => try self.push(.{ .bool_val = false }),
                .pop => {
                    _ = try self.pop();
                },

                .load_local => {
                    const slot = self.readU16();
                    const base = if (self.call_stack.top > 0)
                        self.call_stack.items[self.call_stack.top - 1].base_pointer
                    else
                        0;
                    const val = self.stack.get(base + slot);
                    try self.push(val);
                },
                .store_local => {
                    const slot = self.readU16();
                    const val = try self.pop();
                    const base = if (self.call_stack.top > 0)
                        self.call_stack.items[self.call_stack.top - 1].base_pointer
                    else
                        0;
                    self.stack.set(base + slot, val);
                },

                .add => try self.binaryArith(.add),
                .sub => try self.binaryArith(.sub),
                .mul => try self.binaryArith(.mul),
                .div => try self.binaryArith(.div),
                .mod => try self.binaryArith(.mod),
                .neg => {
                    const a = try self.pop();
                    const result = value_mod.negate(a) catch return error.TypeError;
                    try self.push(result);
                },

                .eq => {
                    const b = try self.pop();
                    const a = try self.pop();
                    try self.push(.{ .bool_val = a.eql(b) });
                },
                .neq => {
                    const b = try self.pop();
                    const a = try self.pop();
                    try self.push(.{ .bool_val = !a.eql(b) });
                },
                .lt => try self.binaryCompare(.lt),
                .gt => try self.binaryCompare(.gt),
                .lte => try self.binaryCompare(.lte),
                .gte => try self.binaryCompare(.gte),

                .op_and => {
                    const b = try self.pop();
                    const a = try self.pop();
                    try self.push(.{ .bool_val = a.isTruthy() and b.isTruthy() });
                },
                .op_or => {
                    const b = try self.pop();
                    const a = try self.pop();
                    try self.push(.{ .bool_val = a.isTruthy() or b.isTruthy() });
                },
                .op_not => {
                    const a = try self.pop();
                    try self.push(.{ .bool_val = !a.isTruthy() });
                },

                .jump => {
                    const offset = self.readI32();
                    self.ip = @intCast(@as(i64, @intCast(self.ip)) + offset);
                },
                .jump_if => {
                    const offset = self.readI32();
                    const cond = try self.pop();
                    if (cond.isTruthy()) {
                        self.ip = @intCast(@as(i64, @intCast(self.ip)) + offset);
                    }
                },
                .jump_if_not => {
                    const offset = self.readI32();
                    const cond = try self.pop();
                    if (!cond.isTruthy()) {
                        self.ip = @intCast(@as(i64, @intCast(self.ip)) + offset);
                    }
                },

                .call => {
                    const func_id = self.readU16();
                    const argc = self.bytecode[self.ip];
                    self.ip += 1;

                    if (func_id >= self.functions.len) return error.InvalidFunction;
                    const func = self.functions[func_id];

                    if (argc != func.arity) return error.ArityMismatch;

                    // Push call frame
                    const frame = CallFrame{
                        .function_id = func_id,
                        .return_ip = self.ip,
                        .base_pointer = @intCast(self.stack.top - argc),
                        .local_count = func.local_count,
                    };
                    self.call_stack.push(frame) catch return error.StackOverflow;

                    // Reserve space for locals beyond params
                    const extra_locals = func.local_count -| argc;
                    var i: u16 = 0;
                    while (i < extra_locals) : (i += 1) {
                        self.stack.push(.{ .null_val = {} }) catch return error.StackOverflow;
                    }

                    self.ip = func.bytecode_offset;
                },
                .ret => {
                    const return_val = self.pop() catch Value{ .null_val = {} };

                    if (self.call_stack.top == 0) {
                        // Return from top-level
                        return return_val;
                    }

                    const frame = self.call_stack.pop() catch return error.RuntimeError;

                    // Pop locals + args
                    self.stack.top = frame.base_pointer;

                    // Push return value
                    try self.push(return_val);

                    self.ip = frame.return_ip;
                },

                .make_array => {
                    const count = self.readU16();
                    // For Phase 1, arrays are not fully supported in VM
                    // Just pop the elements and push null
                    var i: u16 = 0;
                    while (i < count) : (i += 1) {
                        _ = try self.pop();
                    }
                    try self.push(.{ .null_val = {} });
                },
                .make_map => {
                    const count = self.readU16();
                    var i: u16 = 0;
                    while (i < count * 2) : (i += 1) {
                        _ = try self.pop();
                    }
                    try self.push(.{ .null_val = {} });
                },

                .load_index, .store_index, .load_member, .store_member => {
                    // Phase 1: basic stub — skip operands
                    if (op == .load_member or op == .store_member) {
                        _ = self.readU16();
                    }
                    return error.RuntimeError;
                },

                .halt => {
                    if (self.stack.top > 0) {
                        return self.pop() catch null;
                    }
                    return null;
                },
            }
        }
        return null;
    }

    // ---- Helpers ----

    fn binaryArith(self: *VM, op: enum { add, sub, mul, div, mod }) VMError!void {
        const b = try self.pop();
        const a = try self.pop();
        const result = switch (op) {
            .add => value_mod.add(a, b),
            .sub => value_mod.sub(a, b),
            .mul => value_mod.mul(a, b),
            .div => value_mod.div(a, b),
            .mod => value_mod.mod_op(a, b),
        };
        if (result) |val| {
            try self.push(val);
        } else |err| {
            return switch (err) {
                error.TypeError => error.TypeError,
                error.DivisionByZero => error.DivisionByZero,
                error.StringConcat => self.handleStringConcat(a, b),
            };
        }
    }

    fn handleStringConcat(self: *VM, a: Value, b: Value) VMError!void {
        const a_str = a.string;
        const b_str = b.string;
        const new_len = a_str.len + b_str.len;
        const buf = self.allocator.alloc(u8, new_len) catch return error.RuntimeError;
        @memcpy(buf[0..a_str.len], a_str);
        @memcpy(buf[a_str.len..], b_str);
        self.allocated_strings.append(self.allocator, buf) catch return error.RuntimeError;
        try self.push(.{ .string = buf });
    }

    const CompareOp = @typeInfo(@TypeOf(value_mod.compare)).@"fn".params[2].type.?;

    fn binaryCompare(self: *VM, op: CompareOp) VMError!void {
        const b = try self.pop();
        const a = try self.pop();
        const result = value_mod.compare(a, b, op) catch return error.TypeError;
        try self.push(result);
    }

    fn push(self: *VM, val: Value) VMError!void {
        self.stack.push(val) catch return error.StackOverflow;
    }

    fn pop(self: *VM) VMError!Value {
        return self.stack.pop() catch return error.StackUnderflow;
    }

    fn readU16(self: *VM) u16 {
        const val = std.mem.readInt(u16, self.bytecode[self.ip..][0..2], .little);
        self.ip += 2;
        return val;
    }

    fn readI32(self: *VM) i32 {
        const val = std.mem.readInt(i32, self.bytecode[self.ip..][0..4], .little);
        self.ip += 4;
        return val;
    }

    pub fn currentSourceLine(self: *const VM) u32 {
        if (self.debug_lines.len == 0) return 0;

        var best_line: u32 = self.debug_lines[0].source_line;
        for (self.debug_lines) |dl| {
            if (dl.bytecode_offset <= self.ip) {
                best_line = dl.source_line;
            } else {
                break;
            }
        }
        return best_line;
    }
};

// ---- End-to-end test helpers ----

fn compileAndRun(source: []const u8) !?Value {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const diagnostic = @import("../compiler/diagnostic.zig");
    const ast = @import("../compiler/ast.zig");
    const lexer_mod = @import("../compiler/lexer.zig");
    const parser_mod = @import("../compiler/parser.zig");
    const codegen_mod = @import("../compiler/codegen.zig");

    var diags = diagnostic.DiagnosticList.init(allocator);
    var nodes = ast.NodeStore.init(allocator);
    var lexer = lexer_mod.Lexer.init(source, &diags);
    var parser = parser_mod.Parser.init(allocator, &lexer, &nodes, &diags);
    const root = try parser.parseProgram();

    if (diags.hasErrors()) return error.RuntimeError;

    var compiler = codegen_mod.Compiler.init(allocator, &nodes, &diags);
    const module = try compiler.compile(root);

    if (diags.hasErrors()) return error.RuntimeError;

    var vm = VM.init(allocator);
    defer vm.deinit();
    vm.load(module);

    return vm.execute();
}

// Gets the last stored local from the stack (for testing let statements)
fn runAndGetLocal(source: []const u8, local_slot: u32) !Value {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const diagnostic = @import("../compiler/diagnostic.zig");
    const ast_mod = @import("../compiler/ast.zig");
    const lexer_mod = @import("../compiler/lexer.zig");
    const parser_mod = @import("../compiler/parser.zig");
    const codegen_mod = @import("../compiler/codegen.zig");

    var diags = diagnostic.DiagnosticList.init(allocator);
    var nodes = ast_mod.NodeStore.init(allocator);
    var lexer = lexer_mod.Lexer.init(source, &diags);
    var parser = parser_mod.Parser.init(allocator, &lexer, &nodes, &diags);
    const root = try parser.parseProgram();

    var compiler = codegen_mod.Compiler.init(allocator, &nodes, &diags);
    const module = try compiler.compile(root);

    var vm = VM.init(allocator);
    defer vm.deinit();
    vm.load(module);

    _ = vm.execute() catch {};

    return vm.stack.get(local_slot);
}

// ---- Tests ----

test "VM: simple integer let" {
    const val = try runAndGetLocal("let x = 42\n", 0);
    try std.testing.expectEqual(@as(i64, 42), val.int);
}

test "VM: arithmetic" {
    const val = try runAndGetLocal("let x = 2 + 3 * 4\n", 0);
    try std.testing.expectEqual(@as(i64, 14), val.int);
}

test "VM: subtraction and division" {
    const val = try runAndGetLocal("let x = 10 - 3\n", 0);
    try std.testing.expectEqual(@as(i64, 7), val.int);

    const val2 = try runAndGetLocal("let x = 10 / 3\n", 0);
    try std.testing.expectEqual(@as(i64, 3), val2.int);
}

test "VM: float arithmetic" {
    const val = try runAndGetLocal("let x = 3.14 + 1.0\n", 0);
    try std.testing.expect(@abs(val.float - 4.14) < 0.001);
}

test "VM: int-float promotion" {
    const val = try runAndGetLocal("let x = 5 + 2.5\n", 0);
    try std.testing.expect(@abs(val.float - 7.5) < 0.001);
}

test "VM: comparison" {
    const val = try runAndGetLocal("let x = 5 > 3\n", 0);
    try std.testing.expect(val.bool_val);

    const val2 = try runAndGetLocal("let x = 5 < 3\n", 0);
    try std.testing.expect(!val2.bool_val);
}

test "VM: equality" {
    const val = try runAndGetLocal("let x = 42 == 42\n", 0);
    try std.testing.expect(val.bool_val);

    const val2 = try runAndGetLocal("let x = 42 != 43\n", 0);
    try std.testing.expect(val2.bool_val);
}

test "VM: boolean logic" {
    const val = try runAndGetLocal("let x = true\n", 0);
    try std.testing.expect(val.bool_val);

    const val2 = try runAndGetLocal("let x = !true\n", 0);
    try std.testing.expect(!val2.bool_val);
}

test "VM: negation" {
    const val = try runAndGetLocal("let x = -42\n", 0);
    try std.testing.expectEqual(@as(i64, -42), val.int);
}

test "VM: variable assignment" {
    const val = try runAndGetLocal("let x = 10\nx = x + 5\n", 0);
    try std.testing.expectEqual(@as(i64, 15), val.int);
}

test "VM: compound assignment" {
    const val = try runAndGetLocal("let x = 10\nx += 5\n", 0);
    try std.testing.expectEqual(@as(i64, 15), val.int);
}

test "VM: if true branch" {
    const val = try runAndGetLocal("let x = 0\nif true {\n  x = 1\n}\n", 0);
    try std.testing.expectEqual(@as(i64, 1), val.int);
}

test "VM: if false branch" {
    const val = try runAndGetLocal("let x = 0\nif false {\n  x = 1\n} else {\n  x = 2\n}\n", 0);
    try std.testing.expectEqual(@as(i64, 2), val.int);
}

test "VM: while loop" {
    const val = try runAndGetLocal("let x = 0\nwhile x < 5 {\n  x = x + 1\n}\n", 0);
    try std.testing.expectEqual(@as(i64, 5), val.int);
}

test "VM: for range loop" {
    const val = try runAndGetLocal("let sum = 0\nfor i in 0..5 {\n  sum = sum + i\n}\n", 0);
    // sum = 0 + 1 + 2 + 3 + 4 = 10
    try std.testing.expectEqual(@as(i64, 10), val.int);
}

test "VM: nested if" {
    const val = try runAndGetLocal(
        \\let x = 10
        \\let result = 0
        \\if x > 5 {
        \\  if x > 8 {
        \\    result = 1
        \\  } else {
        \\    result = 2
        \\  }
        \\}
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 1), val.int);
}

test "VM: function call" {
    const val = try runAndGetLocal(
        \\fn double(n) {
        \\  return n * 2
        \\}
        \\let x = double(21)
        \\
    , 1); // slot 0 = double (fn ref), slot 1 = x
    try std.testing.expectEqual(@as(i64, 42), val.int);
}

test "VM: recursive function" {
    const val = try runAndGetLocal(
        \\fn factorial(n) {
        \\  if n <= 1 {
        \\    return 1
        \\  }
        \\  return n * factorial(n - 1)
        \\}
        \\let x = factorial(5)
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 120), val.int);
}

test "VM: multiple function calls" {
    // First test: sequential calls stored in vars
    const val1 = try runAndGetLocal(
        \\fn add(a, b) {
        \\  return a + b
        \\}
        \\fn mul(a, b) {
        \\  return a * b
        \\}
        \\let a = mul(2, 3)
        \\let b = mul(4, 5)
        \\let x = add(a, b)
        \\
    , 4); // slot 0=add, 1=mul, 2=a, 3=b, 4=x
    try std.testing.expectEqual(@as(i64, 26), val1.int);
}

test "VM: string literal" {
    const val = try runAndGetLocal("let x = \"hello\"\n", 0);
    try std.testing.expectEqualStrings("hello", val.string);
}

test "VM: null" {
    const val = try runAndGetLocal("let x = null\n", 0);
    try std.testing.expect(val == .null_val);
}

test "VM: source line lookup" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    const debug_lines = [_]DebugLine{
        .{ .bytecode_offset = 0, .source_line = 1 },
        .{ .bytecode_offset = 5, .source_line = 2 },
        .{ .bytecode_offset = 10, .source_line = 3 },
    };
    vm.debug_lines = &debug_lines;

    vm.ip = 0;
    try std.testing.expectEqual(@as(u32, 1), vm.currentSourceLine());

    vm.ip = 7;
    try std.testing.expectEqual(@as(u32, 2), vm.currentSourceLine());

    vm.ip = 15;
    try std.testing.expectEqual(@as(u32, 3), vm.currentSourceLine());
}
