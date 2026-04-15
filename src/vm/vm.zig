const std = @import("std");
const opcodes_mod = @import("opcodes.zig");
const value_mod = @import("value.zig");
const stack_mod = @import("stack.zig");
const codegen = @import("../compiler/codegen.zig");
const event_mod = @import("../runtime/event.zig");

const OpCode = opcodes_mod.OpCode;
const Value = value_mod.Value;
const Event = event_mod.Event;
const Response = event_mod.Response;
const DirectiveArg = event_mod.DirectiveArg;
const DirectiveKind = event_mod.DirectiveKind;
const ChoiceOption = event_mod.ChoiceOption;
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
    closure: ?*value_mod.ClosureHandle = null,
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

    // Heap objects allocated during execution
    allocated_strings: std.ArrayList([]u8) = .empty,
    allocated_arrays: std.ArrayList(*value_mod.ArrayHandle) = .empty,
    allocated_maps: std.ArrayList(*value_mod.MapHandle) = .empty,
    allocated_closures: std.ArrayList(*value_mod.ClosureHandle) = .empty,

    // Active closure for upvalue access (set when executing inside a closure)
    active_closure: ?*value_mod.ClosureHandle = null,

    // Event system state
    suspended: bool = false,
    pending_event: ?Event = null,
    final_value: ?Value = null,
    last_response: Response = .{ .none = {} },
    event_arena: std.heap.ArenaAllocator,
    /// When a choice_prompt event is suspended, this holds the relative
    /// jump offsets (one per option). resumeWith() applies the selected
    /// offset before clearing the arena.
    pending_choice_offsets: ?[]const i32 = null,
    /// IP at the point the choice offsets are measured from (right after the
    /// emit_choice instruction's embedded offset table).
    pending_choice_base_ip: u32 = 0,

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
            .event_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *VM) void {
        for (self.allocated_strings.items) |s| self.allocator.free(s);
        self.allocated_strings.deinit(self.allocator);
        for (self.allocated_maps.items) |m| {
            m.deinit();
            self.allocator.destroy(m);
        }
        self.allocated_maps.deinit(self.allocator);
        for (self.allocated_arrays.items) |a| {
            a.deinit();
            self.allocator.destroy(a);
        }
        self.allocated_arrays.deinit(self.allocator);
        for (self.allocated_closures.items) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.allocated_closures.deinit(self.allocator);
        self.event_arena.deinit();
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
        while (true) {
            const evt = try self.runUntilEvent();
            if (evt == null) break;
            self.resumeWith(.{ .none = {} });
        }
        return self.final_value;
    }

    /// Execute until an event is emitted or execution completes.
    /// Returns the pending event, or null if execution finished.
    /// The returned Event references VM-owned memory and is valid until the
    /// next call to runUntilEvent() or resumeWith().
    pub fn runUntilEvent(self: *VM) VMError!?Event {
        if (self.suspended) return self.pending_event;
        try self.runLoop();
        if (self.suspended) return self.pending_event;
        return null;
    }

    /// Continue execution after an event, optionally passing a response.
    /// The response may influence future behavior (e.g., choice selection).
    /// After this call, any previously-returned Event is invalidated.
    pub fn resumeWith(self: *VM, response: Response) void {
        self.last_response = response;
        self.pending_event = null;
        self.suspended = false;

        // If we suspended on a choice_prompt, apply the selected jump before
        // the arena is reset (offsets are arena-allocated).
        if (self.pending_choice_offsets) |offsets| {
            const selected: u32 = switch (response) {
                .choice_selected => |i| i,
                else => 0,
            };
            const idx: usize = if (selected < offsets.len) selected else 0;
            const target: i64 = @as(i64, @intCast(self.pending_choice_base_ip)) + offsets[idx];
            self.ip = @intCast(target);
            self.pending_choice_offsets = null;
        }

        _ = self.event_arena.reset(.retain_capacity);
    }

    fn runLoop(self: *VM) VMError!void {
        while (self.ip < self.bytecode.len and !self.suspended) {
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

                    // Push call frame (save current closure)
                    const frame = CallFrame{
                        .function_id = func_id,
                        .return_ip = self.ip,
                        .base_pointer = @intCast(self.stack.top - argc),
                        .local_count = func.local_count,
                        .closure = self.active_closure,
                    };
                    self.call_stack.push(frame) catch return error.StackOverflow;
                    self.active_closure = null;

                    // Reserve space for locals beyond params
                    const extra_locals = func.local_count -| argc;
                    var i: u16 = 0;
                    while (i < extra_locals) : (i += 1) {
                        self.stack.push(.{ .null_val = {} }) catch return error.StackOverflow;
                    }

                    self.ip = func.bytecode_offset;
                },
                .call_value => {
                    const argc = self.bytecode[self.ip];
                    self.ip += 1;

                    // The function value is below the arguments on the stack
                    const func_val = self.stack.items[self.stack.top - argc - 1];

                    const func_id: u16 = switch (func_val) {
                        .function => |fid| fid,
                        .closure => |c| c.function_id,
                        else => return error.TypeError,
                    };

                    if (func_id >= self.functions.len) return error.InvalidFunction;
                    const func = self.functions[func_id];

                    if (argc != func.arity) return error.ArityMismatch;

                    // Move arguments down over the function value slot
                    // Stack before: [..., func_val, arg0, arg1, ...]
                    // Stack after:  [..., arg0, arg1, ...]
                    const args_start = self.stack.top - argc;
                    const func_slot = args_start - 1;
                    var j: usize = 0;
                    while (j < argc) : (j += 1) {
                        self.stack.items[func_slot + j] = self.stack.items[args_start + j];
                    }
                    self.stack.top -= 1; // one fewer slot (removed func_val)

                    // Push call frame
                    const frame = CallFrame{
                        .function_id = func_id,
                        .return_ip = self.ip,
                        .base_pointer = @intCast(self.stack.top - argc),
                        .local_count = func.local_count,
                        .closure = self.active_closure,
                    };
                    self.call_stack.push(frame) catch return error.StackOverflow;

                    // Set active closure if calling a closure
                    self.active_closure = switch (func_val) {
                        .closure => |c| c,
                        else => null,
                    };

                    // Reserve space for locals beyond params
                    const extra_locals = func.local_count -| argc;
                    var i: u16 = 0;
                    while (i < extra_locals) : (i += 1) {
                        self.stack.push(.{ .null_val = {} }) catch return error.StackOverflow;
                    }

                    self.ip = func.bytecode_offset;
                },
                .push_function => {
                    const func_id = self.readU16();
                    try self.push(.{ .function = func_id });
                },
                .make_closure => {
                    const func_id = self.readU16();
                    const upvalue_count = self.readU16();

                    const closure = value_mod.ClosureHandle.init(self.allocator, func_id, upvalue_count) catch return error.RuntimeError;
                    self.allocated_closures.append(self.allocator, closure) catch return error.RuntimeError;

                    // Read upvalue descriptors and capture values
                    var i: u16 = 0;
                    while (i < upvalue_count) : (i += 1) {
                        const is_local = self.bytecode[self.ip] == 1;
                        self.ip += 1;
                        const index = self.readU16();

                        if (is_local) {
                            // Capture from current frame's locals
                            const base = if (self.call_stack.top > 0)
                                self.call_stack.items[self.call_stack.top - 1].base_pointer
                            else
                                0;
                            closure.upvalues[i] = self.stack.get(base + index);
                        } else {
                            // Capture from current closure's upvalues
                            if (self.active_closure) |ac| {
                                closure.upvalues[i] = ac.upvalues[index];
                            } else {
                                closure.upvalues[i] = .{ .null_val = {} };
                            }
                        }
                    }

                    try self.push(.{ .closure = closure });
                },
                .load_upvalue => {
                    const index = self.readU16();
                    if (self.active_closure) |c| {
                        if (index < c.upvalues.len) {
                            try self.push(c.upvalues[index]);
                        } else {
                            return error.RuntimeError;
                        }
                    } else {
                        return error.RuntimeError;
                    }
                },
                .store_upvalue => {
                    const index = self.readU16();
                    const val = try self.pop();
                    if (self.active_closure) |c| {
                        if (index < c.upvalues.len) {
                            c.upvalues[index] = val;
                        } else {
                            return error.RuntimeError;
                        }
                    } else {
                        return error.RuntimeError;
                    }
                },
                .ret => {
                    const return_val = self.pop() catch Value{ .null_val = {} };

                    if (self.call_stack.top == 0) {
                        // Return from top-level
                        self.final_value = return_val;
                        self.ip = @intCast(self.bytecode.len);
                        return;
                    }

                    const frame = self.call_stack.pop() catch return error.RuntimeError;

                    // Restore caller's closure context
                    self.active_closure = frame.closure;

                    // Pop locals + args
                    self.stack.top = frame.base_pointer;

                    // Push return value
                    try self.push(return_val);

                    self.ip = frame.return_ip;
                },

                .make_array => {
                    const count = self.readU16();
                    const arr = self.allocateArray() catch return error.RuntimeError;
                    arr.items.ensureTotalCapacity(arr.allocator, count) catch return error.RuntimeError;
                    const base = self.stack.top - count;
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        arr.items.appendAssumeCapacity(self.stack.items[base + i]);
                    }
                    self.stack.top = base;
                    try self.push(.{ .array = arr });
                },
                .make_map => {
                    const count = self.readU16();
                    const m = self.allocateMap() catch return error.RuntimeError;
                    m.entries.ensureTotalCapacity(m.allocator, count) catch return error.RuntimeError;
                    const pair_count: usize = count;
                    const base = self.stack.top - pair_count * 2;
                    var i: usize = 0;
                    while (i < pair_count) : (i += 1) {
                        const key_val = self.stack.items[base + i * 2];
                        const val = self.stack.items[base + i * 2 + 1];
                        const key = switch (key_val) {
                            .string => |s| s,
                            else => return error.TypeError,
                        };
                        m.entries.putAssumeCapacity(key, val);
                    }
                    self.stack.top = base;
                    try self.push(.{ .map = m });
                },

                .load_index => {
                    const index = try self.pop();
                    const obj = try self.pop();
                    switch (obj) {
                        .array => |arr| {
                            const idx = switch (index) {
                                .int => |i| i,
                                else => return error.TypeError,
                            };
                            if (idx < 0 or idx >= @as(i64, @intCast(arr.items.items.len))) {
                                return error.RuntimeError;
                            }
                            try self.push(arr.items.items[@intCast(idx)]);
                        },
                        .map => |m| {
                            const key = switch (index) {
                                .string => |s| s,
                                else => return error.TypeError,
                            };
                            if (m.entries.get(key)) |val| {
                                try self.push(val);
                            } else {
                                try self.push(.{ .null_val = {} });
                            }
                        },
                        else => return error.TypeError,
                    }
                },
                .store_index => {
                    const index = try self.pop();
                    const obj = try self.pop();
                    const val = try self.pop();
                    switch (obj) {
                        .array => |arr| {
                            const idx = switch (index) {
                                .int => |i| i,
                                else => return error.TypeError,
                            };
                            if (idx < 0 or idx >= @as(i64, @intCast(arr.items.items.len))) {
                                return error.RuntimeError;
                            }
                            arr.items.items[@intCast(idx)] = val;
                        },
                        .map => |m| {
                            const key = switch (index) {
                                .string => |s| s,
                                else => return error.TypeError,
                            };
                            m.entries.put(m.allocator, key, val) catch return error.RuntimeError;
                        },
                        else => return error.TypeError,
                    }
                },
                .load_member => {
                    const name_idx = self.readU16();
                    const name = switch (self.constants[name_idx]) {
                        .string => |s| s,
                        else => return error.RuntimeError,
                    };
                    const obj = try self.pop();
                    switch (obj) {
                        .map => |m| {
                            if (m.entries.get(name)) |val| {
                                try self.push(val);
                            } else {
                                try self.push(.{ .null_val = {} });
                            }
                        },
                        else => return error.TypeError,
                    }
                },
                .store_member => {
                    const name_idx = self.readU16();
                    const name = switch (self.constants[name_idx]) {
                        .string => |s| s,
                        else => return error.RuntimeError,
                    };
                    const obj = try self.pop();
                    const val = try self.pop();
                    switch (obj) {
                        .map => |m| {
                            m.entries.put(m.allocator, name, val) catch return error.RuntimeError;
                        },
                        else => return error.TypeError,
                    }
                },

                .call_method => {
                    const name_idx = self.readU16();
                    const argc = self.bytecode[self.ip];
                    self.ip += 1;
                    const method_name = switch (self.constants[name_idx]) {
                        .string => |s| s,
                        else => return error.RuntimeError,
                    };
                    try self.executeMethod(method_name, argc);
                },

                .emit_text => {
                    const text = try self.popString();
                    const speaker = try self.popStringOrNull();
                    self.pending_event = .{ .text_display = .{
                        .speaker = speaker,
                        .text = text,
                    } };
                    self.suspended = true;
                },
                .emit_speaker => {
                    const speaker = try self.popStringOrNull();
                    self.pending_event = .{ .speaker_change = .{ .speaker = speaker } };
                    self.suspended = true;
                },
                .emit_wait => {
                    const ms = self.readU32();
                    self.pending_event = .{ .wait = .{ .ms = ms } };
                    self.suspended = true;
                },
                .emit_save_point => {
                    const name = try self.popString();
                    self.pending_event = .{ .save_point = .{ .name = name } };
                    self.suspended = true;
                },
                .emit_directive => {
                    const kind_byte = self.bytecode[self.ip];
                    self.ip += 1;
                    const arg_count = self.bytecode[self.ip];
                    self.ip += 1;
                    const kind: DirectiveKind = @enumFromInt(kind_byte);
                    try self.emitDirective(kind, arg_count);
                },
                .emit_choice => {
                    const count = self.bytecode[self.ip];
                    self.ip += 1;
                    // Read the in-stream offset table (count × i32).
                    const arena = self.event_arena.allocator();
                    const offsets = arena.alloc(i32, count) catch return error.RuntimeError;
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        offsets[i] = self.readI32();
                    }
                    self.pending_choice_base_ip = self.ip;
                    self.pending_choice_offsets = offsets;
                    try self.emitChoice(count);
                },
                .emit_text_clear => {
                    self.pending_event = .{ .text_clear = {} };
                    self.suspended = true;
                },

                .call_builtin => {
                    const name_idx = self.readU16();
                    const argc = self.bytecode[self.ip];
                    self.ip += 1;
                    const name = switch (self.constants[name_idx]) {
                        .string => |s| s,
                        else => return error.RuntimeError,
                    };
                    try self.executeBuiltin(name, argc);
                },

                .to_str => try self.coerceToString(),

                .halt => {
                    if (self.stack.top > 0) {
                        self.final_value = self.pop() catch null;
                    }
                    self.ip = @intCast(self.bytecode.len);
                    return;
                },
            }
        }
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

    fn readU32(self: *VM) u32 {
        const val = std.mem.readInt(u32, self.bytecode[self.ip..][0..4], .little);
        self.ip += 4;
        return val;
    }

    fn allocateArray(self: *VM) !*value_mod.ArrayHandle {
        const arr = try self.allocator.create(value_mod.ArrayHandle);
        arr.* = value_mod.ArrayHandle.init(self.allocator);
        self.allocated_arrays.append(self.allocator, arr) catch {
            self.allocator.destroy(arr);
            return error.RuntimeError;
        };
        return arr;
    }

    fn allocateMap(self: *VM) !*value_mod.MapHandle {
        const m = try self.allocator.create(value_mod.MapHandle);
        m.* = value_mod.MapHandle.init(self.allocator);
        self.allocated_maps.append(self.allocator, m) catch {
            self.allocator.destroy(m);
            return error.RuntimeError;
        };
        return m;
    }

    fn popString(self: *VM) VMError![]const u8 {
        const v = try self.pop();
        return switch (v) {
            .string => |s| s,
            else => error.TypeError,
        };
    }

    fn popStringOrNull(self: *VM) VMError!?[]const u8 {
        const v = try self.pop();
        return switch (v) {
            .string => |s| s,
            .null_val => null,
            else => error.TypeError,
        };
    }

    fn emitDirective(self: *VM, kind: DirectiveKind, arg_count: u8) VMError!void {
        const arena = self.event_arena.allocator();
        var args: []DirectiveArg = &.{};
        if (arg_count > 0) {
            args = arena.alloc(DirectiveArg, arg_count) catch return error.RuntimeError;
            var i: usize = arg_count;
            while (i > 0) : (i -= 1) {
                const val = try self.pop();
                const key = try self.popString();
                args[i - 1] = .{ .key = key, .value = val };
            }
        }

        self.pending_event = switch (kind) {
            .bg => .{ .bg_change = .{ .image = try self.popString(), .args = args } },
            .sprite_show => .{ .sprite_show = .{ .character = try self.popString(), .args = args } },
            .sprite_hide => .{ .sprite_hide = .{ .character = try self.popString(), .args = args } },
            .bgm_play => .{ .bgm_play = .{ .track = try self.popString(), .args = args } },
            .bgm_stop => .{ .bgm_stop = {} },
            .se_play => .{ .se_play = .{ .sound = try self.popString(), .args = args } },
            .transition => .{ .transition = .{ .kind = try self.popString(), .args = args } },
        };
        self.suspended = true;
    }

    fn coerceToString(self: *VM) VMError!void {
        const v = try self.pop();
        if (v == .string) {
            try self.push(v);
            return;
        }
        const s = switch (v) {
            .int => |i| std.fmt.allocPrint(self.allocator, "{d}", .{i}) catch return error.RuntimeError,
            .float => |f| std.fmt.allocPrint(self.allocator, "{d}", .{f}) catch return error.RuntimeError,
            .bool_val => |b| self.allocator.dupe(u8, if (b) "true" else "false") catch return error.RuntimeError,
            .null_val => self.allocator.dupe(u8, "null") catch return error.RuntimeError,
            .function => |id| std.fmt.allocPrint(self.allocator, "<fn:{d}>", .{id}) catch return error.RuntimeError,
            .closure => |c| std.fmt.allocPrint(self.allocator, "<closure:fn:{d}>", .{c.function_id}) catch return error.RuntimeError,
            .array, .map => blk: {
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                v.formatValue(buf.writer(self.allocator)) catch {
                    buf.deinit(self.allocator);
                    return error.RuntimeError;
                };
                break :blk buf.toOwnedSlice(self.allocator) catch {
                    buf.deinit(self.allocator);
                    return error.RuntimeError;
                };
            },
            .string => unreachable,
        };
        self.allocated_strings.append(self.allocator, s) catch {
            self.allocator.free(s);
            return error.RuntimeError;
        };
        try self.push(.{ .string = s });
    }

    fn emitChoice(self: *VM, count: u8) VMError!void {
        const arena = self.event_arena.allocator();
        const options = arena.alloc(ChoiceOption, count) catch return error.RuntimeError;
        var i: usize = count;
        while (i > 0) : (i -= 1) {
            const target = try self.popString();
            const label = try self.popString();
            const visible_val = try self.pop();
            options[i - 1] = .{
                .label = label,
                .target = target,
                .visible = visible_val.isTruthy(),
            };
        }
        self.pending_event = .{ .choice_prompt = .{ .options = options } };
        self.suspended = true;
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

    fn executeMethod(self: *VM, method_name: []const u8, argc: u8) VMError!void {
        // Stack layout: [receiver, arg1, arg2, ..., argN]
        // receiver is at stack.top - argc - 1
        const receiver_idx = self.stack.top - @as(usize, argc) - 1;
        const receiver = self.stack.items[receiver_idx];

        switch (receiver) {
            .array => |arr| {
                if (std.mem.eql(u8, method_name, "push")) {
                    if (argc != 1) return error.ArityMismatch;
                    const val = try self.pop();
                    _ = try self.pop(); // pop receiver
                    arr.items.append(arr.allocator, val) catch return error.RuntimeError;
                    try self.push(.{ .null_val = {} });
                } else if (std.mem.eql(u8, method_name, "pop")) {
                    if (argc != 0) return error.ArityMismatch;
                    _ = try self.pop(); // pop receiver
                    const val: Value = if (arr.items.items.len > 0) arr.items.pop().? else .{ .null_val = {} };
                    try self.push(val);
                } else if (std.mem.eql(u8, method_name, "len")) {
                    if (argc != 0) return error.ArityMismatch;
                    _ = try self.pop(); // pop receiver
                    try self.push(.{ .int = @intCast(arr.items.items.len) });
                } else if (std.mem.eql(u8, method_name, "contains")) {
                    if (argc != 1) return error.ArityMismatch;
                    const needle = try self.pop();
                    _ = try self.pop(); // pop receiver
                    var found = false;
                    for (arr.items.items) |item| {
                        if (item.eql(needle)) {
                            found = true;
                            break;
                        }
                    }
                    try self.push(.{ .bool_val = found });
                } else {
                    return error.RuntimeError;
                }
            },
            .map => |m| {
                if (std.mem.eql(u8, method_name, "keys")) {
                    if (argc != 0) return error.ArityMismatch;
                    _ = try self.pop(); // pop receiver
                    const keys_arr = self.allocateArray() catch return error.RuntimeError;
                    const key_slice = m.entries.keys();
                    keys_arr.items.ensureTotalCapacity(keys_arr.allocator, key_slice.len) catch return error.RuntimeError;
                    for (key_slice) |k| {
                        keys_arr.items.appendAssumeCapacity(.{ .string = k });
                    }
                    try self.push(.{ .array = keys_arr });
                } else if (std.mem.eql(u8, method_name, "has")) {
                    if (argc != 1) return error.ArityMismatch;
                    const key_val = try self.pop();
                    _ = try self.pop(); // pop receiver
                    const key = switch (key_val) {
                        .string => |s| s,
                        else => return error.TypeError,
                    };
                    try self.push(.{ .bool_val = m.entries.contains(key) });
                } else if (std.mem.eql(u8, method_name, "remove")) {
                    if (argc != 1) return error.ArityMismatch;
                    const key_val = try self.pop();
                    _ = try self.pop(); // pop receiver
                    const key = switch (key_val) {
                        .string => |s| s,
                        else => return error.TypeError,
                    };
                    _ = m.entries.orderedRemove(key);
                    try self.push(.{ .null_val = {} });
                } else if (std.mem.eql(u8, method_name, "len")) {
                    if (argc != 0) return error.ArityMismatch;
                    _ = try self.pop(); // pop receiver
                    try self.push(.{ .int = @intCast(m.entries.count()) });
                } else {
                    return error.RuntimeError;
                }
            },
            .string => |str| {
                if (std.mem.eql(u8, method_name, "len")) {
                    if (argc != 0) return error.ArityMismatch;
                    _ = try self.pop(); // pop receiver
                    try self.push(.{ .int = @intCast(str.len) });
                } else if (std.mem.eql(u8, method_name, "upper")) {
                    if (argc != 0) return error.ArityMismatch;
                    _ = try self.pop();
                    const buf = self.allocator.alloc(u8, str.len) catch return error.RuntimeError;
                    for (str, 0..) |c, i| {
                        buf[i] = std.ascii.toUpper(c);
                    }
                    self.allocated_strings.append(self.allocator, buf) catch return error.RuntimeError;
                    try self.push(.{ .string = buf });
                } else if (std.mem.eql(u8, method_name, "lower")) {
                    if (argc != 0) return error.ArityMismatch;
                    _ = try self.pop();
                    const buf = self.allocator.alloc(u8, str.len) catch return error.RuntimeError;
                    for (str, 0..) |c, i| {
                        buf[i] = std.ascii.toLower(c);
                    }
                    self.allocated_strings.append(self.allocator, buf) catch return error.RuntimeError;
                    try self.push(.{ .string = buf });
                } else if (std.mem.eql(u8, method_name, "contains")) {
                    if (argc != 1) return error.ArityMismatch;
                    const needle_val = try self.pop();
                    _ = try self.pop();
                    const needle = switch (needle_val) {
                        .string => |s| s,
                        else => return error.TypeError,
                    };
                    const found = std.mem.indexOf(u8, str, needle) != null;
                    try self.push(.{ .bool_val = found });
                } else if (std.mem.eql(u8, method_name, "replace")) {
                    if (argc != 2) return error.ArityMismatch;
                    const new_val = try self.pop();
                    const old_val = try self.pop();
                    _ = try self.pop();
                    const old = switch (old_val) {
                        .string => |s| s,
                        else => return error.TypeError,
                    };
                    const new = switch (new_val) {
                        .string => |s| s,
                        else => return error.TypeError,
                    };
                    const replaced = std.mem.replaceOwned(u8, self.allocator, str, old, new) catch return error.RuntimeError;
                    self.allocated_strings.append(self.allocator, replaced) catch return error.RuntimeError;
                    try self.push(.{ .string = replaced });
                } else if (std.mem.eql(u8, method_name, "split")) {
                    if (argc != 1) return error.ArityMismatch;
                    const sep_val = try self.pop();
                    _ = try self.pop();
                    const sep = switch (sep_val) {
                        .string => |s| s,
                        else => return error.TypeError,
                    };
                    const result_arr = self.allocateArray() catch return error.RuntimeError;
                    var iter = std.mem.splitSequence(u8, str, sep);
                    while (iter.next()) |part| {
                        const part_copy = self.allocator.dupe(u8, part) catch return error.RuntimeError;
                        self.allocated_strings.append(self.allocator, part_copy) catch return error.RuntimeError;
                        result_arr.items.append(result_arr.allocator, .{ .string = part_copy }) catch return error.RuntimeError;
                    }
                    try self.push(.{ .array = result_arr });
                } else if (std.mem.eql(u8, method_name, "trim")) {
                    if (argc != 0) return error.ArityMismatch;
                    _ = try self.pop();
                    const trimmed = std.mem.trim(u8, str, " \t\n\r");
                    // trimmed is a slice of the original — need to copy for ownership safety
                    const buf = self.allocator.dupe(u8, trimmed) catch return error.RuntimeError;
                    self.allocated_strings.append(self.allocator, buf) catch return error.RuntimeError;
                    try self.push(.{ .string = buf });
                } else {
                    return error.RuntimeError;
                }
            },
            else => return error.TypeError,
        }
    }

    fn debugPrintValue(_: *VM, prefix: []const u8, v: Value) void {
        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();
        v.formatValue(writer) catch {};
        const written = stream.getWritten();
        std.debug.print("{s}{s}\n", .{ prefix, written });
    }

    fn executeBuiltin(self: *VM, name: []const u8, argc: u8) VMError!void {
        // math module
        if (std.mem.eql(u8, name, "math.abs")) {
            if (argc != 1) return error.ArityMismatch;
            const v = try self.pop();
            switch (v) {
                .int => |i| try self.push(.{ .int = if (i < 0) -i else i }),
                .float => |f| try self.push(.{ .float = @abs(f) }),
                else => return error.TypeError,
            }
        } else if (std.mem.eql(u8, name, "math.min")) {
            if (argc != 2) return error.ArityMismatch;
            const b = try self.pop();
            const a = try self.pop();
            const cmp = value_mod.compare(a, b, .lt) catch return error.TypeError;
            try self.push(if (cmp.bool_val) a else b);
        } else if (std.mem.eql(u8, name, "math.max")) {
            if (argc != 2) return error.ArityMismatch;
            const b = try self.pop();
            const a = try self.pop();
            const cmp = value_mod.compare(a, b, .gt) catch return error.TypeError;
            try self.push(if (cmp.bool_val) a else b);
        } else if (std.mem.eql(u8, name, "math.floor")) {
            if (argc != 1) return error.ArityMismatch;
            const v = try self.pop();
            switch (v) {
                .float => |f| try self.push(.{ .int = @intFromFloat(@floor(f)) }),
                .int => try self.push(v),
                else => return error.TypeError,
            }
        } else if (std.mem.eql(u8, name, "math.ceil")) {
            if (argc != 1) return error.ArityMismatch;
            const v = try self.pop();
            switch (v) {
                .float => |f| try self.push(.{ .int = @intFromFloat(@ceil(f)) }),
                .int => try self.push(v),
                else => return error.TypeError,
            }
        } else if (std.mem.eql(u8, name, "math.random")) {
            if (argc != 2) return error.ArityMismatch;
            const max_val = try self.pop();
            const min_val = try self.pop();
            const min_i = switch (min_val) {
                .int => |i| i,
                else => return error.TypeError,
            };
            const max_i = switch (max_val) {
                .int => |i| i,
                else => return error.TypeError,
            };
            if (min_i > max_i) return error.RuntimeError;
            // Simple deterministic random for now (seed-based in future)
            // Use a basic LCG seeded from IP to provide some variation
            const seed: u64 = @intCast(self.ip);
            const range: u64 = @intCast(max_i - min_i + 1);
            const rand_val: i64 = min_i + @as(i64, @intCast((seed *% 6364136223846793005 +% 1442695040888963407) % range));
            try self.push(.{ .int = rand_val });
        }
        // debug module
        else if (std.mem.eql(u8, name, "debug.log")) {
            if (argc != 1) return error.ArityMismatch;
            const v = try self.pop();
            self.debugPrintValue("[debug] ", v);
            try self.push(.{ .null_val = {} });
        } else if (std.mem.eql(u8, name, "debug.dump")) {
            if (argc != 1) return error.ArityMismatch;
            const v = try self.pop();
            std.debug.print("[dump] type={s} value=", .{v.typeName()});
            self.debugPrintValue("", v);
            try self.push(.{ .null_val = {} });
        } else if (std.mem.eql(u8, name, "debug.assert")) {
            if (argc != 1 and argc != 2) return error.ArityMismatch;
            var msg: []const u8 = "assertion failed";
            if (argc == 2) {
                const msg_val = try self.pop();
                msg = switch (msg_val) {
                    .string => |s| s,
                    else => "assertion failed",
                };
            }
            const cond = try self.pop();
            if (!cond.isTruthy()) {
                std.debug.print("[assert] {s}\n", .{msg});
                return error.RuntimeError;
            }
            try self.push(.{ .null_val = {} });
        } else {
            return error.RuntimeError;
        }
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
    var lexer = lexer_mod.Lexer.init(source, &diags, .logic);
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
    var lexer = lexer_mod.Lexer.init(source, &diags, .logic);
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

// ---- EMIT opcode tests ----

// Build a minimal CompiledModule with a single main function (function 0,
// zero arity, zero locals) whose body is the provided bytecode.
fn buildEmitModule(
    allocator: std.mem.Allocator,
    constants: []const Constant,
    bytecode: []const u8,
) !CompiledModule {
    const bc_copy = try allocator.dupe(u8, bytecode);
    const functions = try allocator.alloc(FunctionEntry, 1);
    functions[0] = .{
        .name_idx = 0,
        .arity = 0,
        .bytecode_offset = 0,
        .local_count = 0,
    };
    return .{
        .bytecode = bc_copy,
        .constants = constants,
        .functions = functions,
        .debug_lines = &.{},
    };
}

test "VM: emit_text produces text_display event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Constants: 0="Alice", 1="Hello"
    const constants = [_]Constant{
        .{ .string = "Alice" },
        .{ .string = "Hello" },
    };

    // Bytecode: push_const 0 (speaker), push_const 1 (text), emit_text, halt
    const bc = [_]u8{
        @intFromEnum(OpCode.push_const), 0, 0,
        @intFromEnum(OpCode.push_const), 1, 0,
        @intFromEnum(OpCode.emit_text),
        @intFromEnum(OpCode.halt),
    };

    const module = try buildEmitModule(allocator, &constants, &bc);
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.load(module);

    const evt = try vm.runUntilEvent();
    try std.testing.expect(evt != null);
    try std.testing.expectEqual(event_mod.EventTag.text_display, @as(event_mod.EventTag, evt.?));
    try std.testing.expectEqualStrings("Alice", evt.?.text_display.speaker.?);
    try std.testing.expectEqualStrings("Hello", evt.?.text_display.text);

    vm.resumeWith(.{ .text_ack = {} });
    const next = try vm.runUntilEvent();
    try std.testing.expect(next == null); // reaches halt
}

test "VM: emit_text with null speaker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const constants = [_]Constant{.{ .string = "narration" }};
    const bc = [_]u8{
        @intFromEnum(OpCode.push_null),
        @intFromEnum(OpCode.push_const), 0, 0,
        @intFromEnum(OpCode.emit_text),
        @intFromEnum(OpCode.halt),
    };

    const module = try buildEmitModule(allocator, &constants, &bc);
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.load(module);

    const evt = try vm.runUntilEvent();
    try std.testing.expect(evt != null);
    try std.testing.expect(evt.?.text_display.speaker == null);
    try std.testing.expectEqualStrings("narration", evt.?.text_display.text);
}

test "VM: emit_wait carries ms operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // emit_wait 500ms, halt
    const bc = [_]u8{
        @intFromEnum(OpCode.emit_wait), 0xF4, 0x01, 0x00, 0x00, // 500
        @intFromEnum(OpCode.halt),
    };

    const module = try buildEmitModule(allocator, &.{}, &bc);
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.load(module);

    const evt = try vm.runUntilEvent();
    try std.testing.expect(evt != null);
    try std.testing.expectEqual(@as(u32, 500), evt.?.wait.ms);
}

test "VM: emit_directive bg with args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // bg "forest.png" fade=...  → push image, push key, push value, emit_directive
    const constants = [_]Constant{
        .{ .string = "forest.png" },
        .{ .string = "fade" },
        .{ .string = "slow" },
    };
    const bc = [_]u8{
        @intFromEnum(OpCode.push_const), 0, 0, // image
        @intFromEnum(OpCode.push_const), 1, 0, // key
        @intFromEnum(OpCode.push_const), 2, 0, // value
        @intFromEnum(OpCode.emit_directive),
        @intFromEnum(DirectiveKind.bg),
        1, // arg_count
        @intFromEnum(OpCode.halt),
    };

    const module = try buildEmitModule(allocator, &constants, &bc);
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.load(module);

    const evt = try vm.runUntilEvent();
    try std.testing.expect(evt != null);
    try std.testing.expectEqual(event_mod.EventTag.bg_change, @as(event_mod.EventTag, evt.?));
    try std.testing.expectEqualStrings("forest.png", evt.?.bg_change.image);
    try std.testing.expectEqual(@as(usize, 1), evt.?.bg_change.args.len);
    try std.testing.expectEqualStrings("fade", evt.?.bg_change.args[0].key);
    try std.testing.expectEqualStrings("slow", evt.?.bg_change.args[0].value.string);
}

test "VM: emit_choice builds options list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const constants = [_]Constant{
        .{ .string = "Attack" }, .{ .string = "attack_label" },
        .{ .string = "Defend" }, .{ .string = "defend_label" },
    };
    const bc = [_]u8{
        // item 0: visible=true, label, target
        @intFromEnum(OpCode.push_true),
        @intFromEnum(OpCode.push_const), 0, 0,
        @intFromEnum(OpCode.push_const), 1, 0,
        // item 1: visible=true, label, target
        @intFromEnum(OpCode.push_true),
        @intFromEnum(OpCode.push_const), 2, 0,
        @intFromEnum(OpCode.push_const), 3, 0,
        @intFromEnum(OpCode.emit_choice), 2,
        // Two i32 offsets (little-endian) — unused by this test; both 0.
        0, 0, 0, 0,
        0, 0, 0, 0,
        @intFromEnum(OpCode.halt),
    };

    const module = try buildEmitModule(allocator, &constants, &bc);
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.load(module);

    const evt = try vm.runUntilEvent();
    try std.testing.expect(evt != null);
    const opts = evt.?.choice_prompt.options;
    try std.testing.expectEqual(@as(usize, 2), opts.len);
    try std.testing.expectEqualStrings("Attack", opts[0].label);
    try std.testing.expectEqualStrings("attack_label", opts[0].target);
    try std.testing.expectEqualStrings("Defend", opts[1].label);
    try std.testing.expectEqualStrings("defend_label", opts[1].target);
}

test "VM: resume invalidates prior event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const constants = [_]Constant{ .{ .string = "a" }, .{ .string = "b" } };
    const bc = [_]u8{
        @intFromEnum(OpCode.push_null),
        @intFromEnum(OpCode.push_const), 0, 0,
        @intFromEnum(OpCode.emit_text),
        @intFromEnum(OpCode.push_null),
        @intFromEnum(OpCode.push_const), 1, 0,
        @intFromEnum(OpCode.emit_text),
        @intFromEnum(OpCode.halt),
    };

    const module = try buildEmitModule(allocator, &constants, &bc);
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.load(module);

    const e1 = try vm.runUntilEvent();
    try std.testing.expectEqualStrings("a", e1.?.text_display.text);
    vm.resumeWith(.{ .text_ack = {} });

    const e2 = try vm.runUntilEvent();
    try std.testing.expectEqualStrings("b", e2.?.text_display.text);
}

// Compile a scenario source and execute it, collecting emitted events
// along with a simple auto-response policy. Returns an owned slice of
// event tag names (arena-backed).
fn runScenarioCollect(
    allocator: std.mem.Allocator,
    source: []const u8,
) !std.ArrayList([]const u8) {
    const diagnostic = @import("../compiler/diagnostic.zig");
    const ast_mod = @import("../compiler/ast.zig");
    const lexer_mod = @import("../compiler/lexer.zig");
    const parser_mod = @import("../compiler/parser.zig");
    const codegen_mod = @import("../compiler/codegen.zig");

    var diags = diagnostic.DiagnosticList.init(allocator);
    var nodes = ast_mod.NodeStore.init(allocator);
    var lexer = lexer_mod.Lexer.init(source, &diags, .scenario);
    var parser = parser_mod.Parser.init(allocator, &lexer, &nodes, &diags);
    const root = try parser.parseProgram();
    if (diags.hasErrors()) return error.ParseError;

    var compiler = codegen_mod.Compiler.init(allocator, &nodes, &diags);
    const module = try compiler.compile(root);
    if (diags.hasErrors()) return error.CompileError;

    var vm = VM.init(allocator);
    defer vm.deinit();
    vm.load(module);

    var tags: std.ArrayList([]const u8) = .empty;
    while (true) {
        const evt_opt = try vm.runUntilEvent();
        const evt = evt_opt orelse break;
        try tags.append(allocator, @tagName(@as(event_mod.EventTag, evt)));
        const response: Response = switch (evt) {
            .choice_prompt => .{ .choice_selected = 0 },
            .text_display => .{ .text_ack = {} },
            .wait => .{ .wait_completed = {} },
            else => .{ .none = {} },
        };
        vm.resumeWith(response);
    }
    return tags;
}

test "integration: greeting scenario emits expected event sequence" {
    // Mirror of tests/fixtures/greeting.neru kept inline because @embedFile
    // cannot reach outside the module root.
    const source =
        \\@speaker Alice
        \\Hello, traveler.
        \\@wait 500
        \\How are you today?
        \\@clear
        \\@speaker Bob
        \\Just passing through.
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tags = try runScenarioCollect(arena.allocator(), source);

    const expected = [_][]const u8{
        "speaker_change", // @speaker Alice
        "text_display", // "Hello, traveler."
        "wait", // @wait 500
        "text_display", // "How are you today?"
        "text_clear", // @clear
        "speaker_change", // @speaker Bob
        "text_display", // "Just passing through."
    };
    try std.testing.expectEqual(expected.len, tags.items.len);
    for (expected, tags.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "integration: media directives emit expected events" {
    const source =
        \\@bg forest.png --fade=slow --duration=500
        \\@show taro --pos=center
        \\@bgm theme.ogg --volume=0.8
        \\@se door.wav
        \\@transition wipe --direction=left
        \\@hide taro
        \\@bgm_stop
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tags = try runScenarioCollect(arena.allocator(), source);

    const expected = [_][]const u8{
        "bg_change",
        "sprite_show",
        "bgm_play",
        "se_play",
        "transition",
        "sprite_hide",
        "bgm_stop",
    };
    try std.testing.expectEqual(expected.len, tags.items.len);
    for (expected, tags.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "integration: media directive options are threaded through" {
    const source =
        \\@bg forest.png --fade=slow --duration=500
        \\
    ;
    const diagnostic = @import("../compiler/diagnostic.zig");
    const ast_mod = @import("../compiler/ast.zig");
    const lexer_mod = @import("../compiler/lexer.zig");
    const parser_mod = @import("../compiler/parser.zig");
    const codegen_mod = @import("../compiler/codegen.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var diags = diagnostic.DiagnosticList.init(allocator);
    var nodes = ast_mod.NodeStore.init(allocator);
    var lexer = lexer_mod.Lexer.init(source, &diags, .scenario);
    var parser = parser_mod.Parser.init(allocator, &lexer, &nodes, &diags);
    const root = try parser.parseProgram();
    try std.testing.expect(!diags.hasErrors());

    var compiler = codegen_mod.Compiler.init(allocator, &nodes, &diags);
    const module = try compiler.compile(root);
    try std.testing.expect(!diags.hasErrors());

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.load(module);

    const evt = try vm.runUntilEvent();
    const bg = evt.?.bg_change;
    try std.testing.expectEqualStrings("forest.png", bg.image);
    try std.testing.expectEqual(@as(usize, 2), bg.args.len);
    try std.testing.expectEqualStrings("fade", bg.args[0].key);
    try std.testing.expectEqualStrings("slow", bg.args[0].value.string);
    try std.testing.expectEqualStrings("duration", bg.args[1].key);
    try std.testing.expectEqual(@as(i64, 500), bg.args[1].value.int);
}

test "integration: @goto skips intermediate statements" {
    const source =
        \\@speaker N
        \\first
        \\@goto after
        \\skipped
        \\#after
        \\reached
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tags = try runScenarioCollect(arena.allocator(), source);

    const expected = [_][]const u8{
        "speaker_change",
        "text_display", // "first"
        "text_display", // "reached" (skipped line was bypassed)
    };
    try std.testing.expectEqual(expected.len, tags.items.len);
    for (expected, tags.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "integration: #choice jumps to selected target" {
    const source =
        \\pick one
        \\#choice
        \\  - "A" -> path_a
        \\  - "B" -> path_b
        \\
        \\#path_a
        \\you chose A
        \\@goto done
        \\
        \\#path_b
        \\you chose B
        \\@goto done
        \\
        \\#done
        \\end
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // runScenarioCollect auto-selects 0 for choice_prompt, so we expect the
    // "A" branch to execute.
    const tags = try runScenarioCollect(arena.allocator(), source);

    const expected = [_][]const u8{
        "text_display", // "pick one"
        "choice_prompt",
        "text_display", // "you chose A"
        "text_display", // "end"
    };
    try std.testing.expectEqual(expected.len, tags.items.len);
    for (expected, tags.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "integration: unresolved label is reported" {
    const source =
        \\@goto missing
        \\
    ;
    const diagnostic = @import("../compiler/diagnostic.zig");
    const ast_mod = @import("../compiler/ast.zig");
    const lexer_mod = @import("../compiler/lexer.zig");
    const parser_mod = @import("../compiler/parser.zig");
    const codegen_mod = @import("../compiler/codegen.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var diags = diagnostic.DiagnosticList.init(allocator);
    var nodes = ast_mod.NodeStore.init(allocator);
    var lexer = lexer_mod.Lexer.init(source, &diags, .scenario);
    var parser = parser_mod.Parser.init(allocator, &lexer, &nodes, &diags);
    const root = try parser.parseProgram();
    try std.testing.expect(!diags.hasErrors());

    var compiler = codegen_mod.Compiler.init(allocator, &nodes, &diags);
    _ = try compiler.compile(root);
    try std.testing.expect(diags.hasErrors());
}

test "integration: scenario @if picks then branch" {
    const source =
        \\@if 10 > 5
        \\then branch
        \\@else
        \\else branch
        \\@end
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tags = try runScenarioCollect(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), tags.items.len);
    try std.testing.expectEqualStrings("text_display", tags.items[0]);
}

test "integration: scenario @elif selects matching branch" {
    const source =
        \\@if 1 == 0
        \\never
        \\@elif 2 == 2
        \\elif hit
        \\@else
        \\else
        \\@end
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tags = try runScenarioCollect(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), tags.items.len);
    try std.testing.expectEqualStrings("text_display", tags.items[0]);
}

test "integration: conditional choice hides false options" {
    const source =
        \\#choice
        \\  - "visible" -> a
        \\  - "hidden" -> b @if 1 == 0
        \\
        \\#a
        \\picked a
        \\@goto done
        \\#b
        \\picked b
        \\@goto done
        \\#done
        \\end
        \\
    ;
    const diagnostic = @import("../compiler/diagnostic.zig");
    const ast_mod = @import("../compiler/ast.zig");
    const lexer_mod = @import("../compiler/lexer.zig");
    const parser_mod = @import("../compiler/parser.zig");
    const codegen_mod = @import("../compiler/codegen.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var diags = diagnostic.DiagnosticList.init(allocator);
    var nodes = ast_mod.NodeStore.init(allocator);
    var lexer = lexer_mod.Lexer.init(source, &diags, .scenario);
    var parser = parser_mod.Parser.init(allocator, &lexer, &nodes, &diags);
    const root = try parser.parseProgram();
    try std.testing.expect(!diags.hasErrors());

    var compiler = codegen_mod.Compiler.init(allocator, &nodes, &diags);
    const module = try compiler.compile(root);
    try std.testing.expect(!diags.hasErrors());

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.load(module);

    const evt = try vm.runUntilEvent();
    const prompt = evt.?.choice_prompt;
    try std.testing.expectEqual(@as(usize, 2), prompt.options.len);
    try std.testing.expect(prompt.options[0].visible);
    try std.testing.expect(!prompt.options[1].visible);
}

test "integration: text line carries compile-time speaker" {
    const source =
        \\@speaker Alice
        \\Hello
        \\
    ;
    const diagnostic = @import("../compiler/diagnostic.zig");
    const ast_mod = @import("../compiler/ast.zig");
    const lexer_mod = @import("../compiler/lexer.zig");
    const parser_mod = @import("../compiler/parser.zig");
    const codegen_mod = @import("../compiler/codegen.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var diags = diagnostic.DiagnosticList.init(allocator);
    var nodes = ast_mod.NodeStore.init(allocator);
    var lexer = lexer_mod.Lexer.init(source, &diags, .scenario);
    var parser = parser_mod.Parser.init(allocator, &lexer, &nodes, &diags);
    const root = try parser.parseProgram();
    try std.testing.expect(!diags.hasErrors());

    var compiler = codegen_mod.Compiler.init(allocator, &nodes, &diags);
    const module = try compiler.compile(root);
    try std.testing.expect(!diags.hasErrors());

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.load(module);

    // First event: speaker_change.
    const e1 = try vm.runUntilEvent();
    try std.testing.expectEqualStrings("Alice", e1.?.speaker_change.speaker.?);
    vm.resumeWith(.{ .none = {} });

    // Second event: text_display, speaker should be Alice.
    const e2 = try vm.runUntilEvent();
    try std.testing.expectEqualStrings("Alice", e2.?.text_display.speaker.?);
    try std.testing.expectEqualStrings("Hello", e2.?.text_display.text);
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

// ---- Phase 3.1: Data structure tests ----

test "VM: array literal" {
    const val = try runAndGetLocal(
        \\let arr = [1, 2, 3]
        \\let length = arr.len()
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 3), val.int);
}

test "VM: empty array" {
    const val = try runAndGetLocal(
        \\let arr = []
        \\let length = arr.len()
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 0), val.int);
}

test "VM: array index access" {
    const val = try runAndGetLocal(
        \\let arr = [10, 20, 30]
        \\let x = arr[1]
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 20), val.int);
}

test "VM: array index assignment" {
    const val = try runAndGetLocal(
        \\let arr = [10, 20, 30]
        \\arr[1] = 99
        \\let x = arr[1]
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 99), val.int);
}

test "VM: array push" {
    const val = try runAndGetLocal(
        \\let arr = [1, 2]
        \\arr.push(3)
        \\let length = arr.len()
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 3), val.int);
}

test "VM: array pop" {
    const val = try runAndGetLocal(
        \\let arr = [1, 2, 3]
        \\let popped = arr.pop()
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 3), val.int);
}

test "VM: array contains" {
    const val = try runAndGetLocal(
        \\let arr = [10, 20, 30]
        \\let found = arr.contains(20)
        \\
    , 1);
    try std.testing.expect(val.bool_val);
}

test "VM: array contains false" {
    const val = try runAndGetLocal(
        \\let arr = [10, 20, 30]
        \\let found = arr.contains(99)
        \\
    , 1);
    try std.testing.expect(!val.bool_val);
}

test "VM: map literal" {
    const val = try runAndGetLocal(
        \\let m = {"a": 1, "b": 2}
        \\let length = m.len()
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 2), val.int);
}

test "VM: map index access" {
    const val = try runAndGetLocal(
        \\let m = {"x": 42}
        \\let v = m["x"]
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 42), val.int);
}

test "VM: map member access" {
    const val = try runAndGetLocal(
        \\let m = {"x": 42}
        \\let v = m.x
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 42), val.int);
}

test "VM: map index assignment" {
    const val = try runAndGetLocal(
        \\let m = {"a": 1}
        \\m["b"] = 2
        \\let length = m.len()
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 2), val.int);
}

test "VM: map has" {
    const val = try runAndGetLocal(
        \\let m = {"key": 1}
        \\let found = m.has("key")
        \\
    , 1);
    try std.testing.expect(val.bool_val);
}

test "VM: map has false" {
    const val = try runAndGetLocal(
        \\let m = {"key": 1}
        \\let found = m.has("nope")
        \\
    , 1);
    try std.testing.expect(!val.bool_val);
}

test "VM: map remove" {
    const val = try runAndGetLocal(
        \\let m = {"a": 1, "b": 2}
        \\m.remove("a")
        \\let length = m.len()
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 1), val.int);
}

test "VM: map keys" {
    const val = try runAndGetLocal(
        \\let m = {"a": 1, "b": 2}
        \\let k = m.keys()
        \\let length = k.len()
        \\
    , 2);
    try std.testing.expectEqual(@as(i64, 2), val.int);
}

test "VM: nested array" {
    const val = try runAndGetLocal(
        \\let arr = [[1, 2], [3, 4]]
        \\let inner = arr[1]
        \\let x = inner[0]
        \\
    , 2);
    try std.testing.expectEqual(@as(i64, 3), val.int);
}

test "VM: nested map" {
    const val = try runAndGetLocal(
        \\let m = {"inner": {"val": 99}}
        \\let v = m["inner"]
        \\let x = v["val"]
        \\
    , 2);
    try std.testing.expectEqual(@as(i64, 99), val.int);
}

test "VM: string len method" {
    const val = try runAndGetLocal(
        \\let s = "hello"
        \\let n = s.len()
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 5), val.int);
}

test "VM: map missing key returns null" {
    const val = try runAndGetLocal(
        \\let m = {"a": 1}
        \\let v = m["missing"]
        \\
    , 1);
    try std.testing.expect(val == .null_val);
}

// ---- Phase 3.2: First-class functions & closures ----

test "VM: function assigned to variable" {
    const val = try runAndGetLocal(
        \\fn double(n) {
        \\  return n * 2
        \\}
        \\let f = double
        \\let result = f(21)
        \\
    , 2); // slot 0 = double, slot 1 = f, slot 2 = result
    try std.testing.expectEqual(@as(i64, 42), val.int);
}

test "VM: function passed as argument" {
    const val = try runAndGetLocal(
        \\fn apply(func, x) {
        \\  return func(x)
        \\}
        \\fn triple(n) {
        \\  return n * 3
        \\}
        \\let result = apply(triple, 10)
        \\
    , 2); // slot 0 = apply, slot 1 = triple, slot 2 = result
    try std.testing.expectEqual(@as(i64, 30), val.int);
}

test "VM: function returned from function" {
    const val = try runAndGetLocal(
        \\fn get_doubler() {
        \\  fn doubler(n) {
        \\    return n * 2
        \\  }
        \\  return doubler
        \\}
        \\let f = get_doubler()
        \\let result = f(15)
        \\
    , 2); // slot 0 = get_doubler, slot 1 = f, slot 2 = result
    try std.testing.expectEqual(@as(i64, 30), val.int);
}

test "VM: function value is truthy" {
    const val = try runAndGetLocal(
        \\fn noop() { return null }
        \\let result = false
        \\if noop {
        \\  result = true
        \\}
        \\
    , 1); // slot 0 = noop, slot 1 = result
    try std.testing.expect(val.bool_val);
}

test "VM: function value equality" {
    const val = try runAndGetLocal(
        \\fn foo() { return 1 }
        \\let a = foo
        \\let b = foo
        \\let same = a == b
        \\
    , 3); // slot 0 = foo, 1 = a, 2 = b, 3 = same
    try std.testing.expect(val.bool_val);
}

test "VM: closure captures variable" {
    const val = try runAndGetLocal(
        \\fn make_adder(x) {
        \\  fn adder(y) {
        \\    return x + y
        \\  }
        \\  return adder
        \\}
        \\let add5 = make_adder(5)
        \\let result = add5(10)
        \\
    , 2); // slot 0 = make_adder, slot 1 = add5, slot 2 = result
    try std.testing.expectEqual(@as(i64, 15), val.int);
}

test "VM: closure captures multiple variables" {
    const val = try runAndGetLocal(
        \\fn make_calc(a, b) {
        \\  fn calc(c) {
        \\    return a + b + c
        \\  }
        \\  return calc
        \\}
        \\let f = make_calc(10, 20)
        \\let result = f(30)
        \\
    , 2); // slot 0 = make_calc, slot 1 = f, slot 2 = result
    try std.testing.expectEqual(@as(i64, 60), val.int);
}

test "VM: multiple closures from same factory" {
    const val = try runAndGetLocal(
        \\fn make_adder(x) {
        \\  fn adder(y) {
        \\    return x + y
        \\  }
        \\  return adder
        \\}
        \\let add3 = make_adder(3)
        \\let add7 = make_adder(7)
        \\let r1 = add3(10)
        \\let r2 = add7(10)
        \\let result = r1 + r2
        \\
    , 5); // slot 0=make_adder, 1=add3, 2=add7, 3=r1, 4=r2, 5=result
    try std.testing.expectEqual(@as(i64, 30), val.int); // 13 + 17
}

test "VM: higher-order function with closure" {
    const val = try runAndGetLocal(
        \\fn apply(func, x) {
        \\  return func(x)
        \\}
        \\fn make_multiplier(factor) {
        \\  fn mul(n) {
        \\    return n * factor
        \\  }
        \\  return mul
        \\}
        \\let times3 = make_multiplier(3)
        \\let result = apply(times3, 7)
        \\
    , 3); // slot 0=apply, 1=make_multiplier, 2=times3, 3=result
    try std.testing.expectEqual(@as(i64, 21), val.int);
}

// ---- Phase 3.3: Loop enhancements ----

test "VM: for-in array loop" {
    const val = try runAndGetLocal(
        \\let arr = [10, 20, 30]
        \\let sum = 0
        \\for item in arr {
        \\  sum = sum + item
        \\}
        \\
    , 1); // slot 0 = arr, slot 1 = sum
    try std.testing.expectEqual(@as(i64, 60), val.int);
}

test "VM: for-in array with break" {
    const val = try runAndGetLocal(
        \\let arr = [1, 2, 3, 4, 5]
        \\let sum = 0
        \\for item in arr {
        \\  if item == 4 {
        \\    break
        \\  }
        \\  sum = sum + item
        \\}
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 6), val.int);
}

test "VM: for-in array with continue" {
    const val = try runAndGetLocal(
        \\let arr = [1, 2, 3, 4, 5]
        \\let sum = 0
        \\for item in arr {
        \\  if item == 3 {
        \\    continue
        \\  }
        \\  sum = sum + item
        \\}
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 12), val.int);
}

test "VM: for-in empty array" {
    const val = try runAndGetLocal(
        \\let arr = []
        \\let count = 0
        \\for item in arr {
        \\  count = count + 1
        \\}
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 0), val.int);
}

test "VM: nested for loops" {
    const val = try runAndGetLocal(
        \\let sum = 0
        \\for i in 0..3 {
        \\  for j in 0..3 {
        \\    sum = sum + 1
        \\  }
        \\}
        \\
    , 0); // slot 0 = sum
    try std.testing.expectEqual(@as(i64, 9), val.int);
}

test "VM: nested for-in with range" {
    const val = try runAndGetLocal(
        \\let arr = [10, 20, 30]
        \\let sum = 0
        \\for item in arr {
        \\  for i in 0..item {
        \\    sum = sum + 1
        \\  }
        \\}
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 60), val.int);
}

test "VM: nested for-in arrays" {
    const val = try runAndGetLocal(
        \\let a = [1, 2]
        \\let b = [10, 20]
        \\let sum = 0
        \\for x in a {
        \\  for y in b {
        \\    sum = sum + x * y
        \\  }
        \\}
        \\
    , 2); // slot 0=a, 1=b, 2=sum
    try std.testing.expectEqual(@as(i64, 90), val.int); // 1*10+1*20+2*10+2*20
}

test "VM: nested loop with break in inner" {
    const val = try runAndGetLocal(
        \\let sum = 0
        \\for i in 0..3 {
        \\  for j in 0..10 {
        \\    if j == 2 {
        \\      break
        \\    }
        \\    sum = sum + 1
        \\  }
        \\}
        \\
    , 0);
    try std.testing.expectEqual(@as(i64, 6), val.int); // 3 * 2
}

test "VM: while with break and continue" {
    const val = try runAndGetLocal(
        \\let sum = 0
        \\let i = 0
        \\while i < 10 {
        \\  i = i + 1
        \\  if i == 5 {
        \\    continue
        \\  }
        \\  if i == 8 {
        \\    break
        \\  }
        \\  sum = sum + i
        \\}
        \\
    , 0); // slot 0 = sum
    try std.testing.expectEqual(@as(i64, 23), val.int); // 1+2+3+4+6+7
}

// ---- Phase 3.4: String operations ----
// NOTE: Tests for VM-allocated strings (concat, upper, etc.) compare inside the
// VM and check a bool/int result, because runAndGetLocal's arena is freed before
// the caller can inspect string pointers.

test "VM: string concatenation" {
    const val = try runAndGetLocal(
        \\let c = "hello" + " world"
        \\let r = c == "hello world"
        \\
    , 1);
    try std.testing.expect(val.bool_val);
}

test "VM: string concat length" {
    const val = try runAndGetLocal(
        \\let c = "abc" + "def"
        \\let n = c.len()
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 6), val.int);
}

test "VM: string len" {
    const val = try runAndGetLocal(
        \\let s = "hello"
        \\let n = s.len()
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 5), val.int);
}

test "VM: string upper" {
    const val = try runAndGetLocal(
        \\let r = "hello".upper() == "HELLO"
        \\
    , 0);
    try std.testing.expect(val.bool_val);
}

test "VM: string lower" {
    const val = try runAndGetLocal(
        \\let r = "HELLO".lower() == "hello"
        \\
    , 0);
    try std.testing.expect(val.bool_val);
}

test "VM: string contains true" {
    const val = try runAndGetLocal(
        \\let r = "hello world".contains("world")
        \\
    , 0);
    try std.testing.expect(val.bool_val);
}

test "VM: string contains false" {
    const val = try runAndGetLocal(
        \\let r = "hello world".contains("xyz")
        \\
    , 0);
    try std.testing.expect(!val.bool_val);
}

test "VM: string replace" {
    const val = try runAndGetLocal(
        \\let r = "hello world".replace("world", "zig") == "hello zig"
        \\
    , 0);
    try std.testing.expect(val.bool_val);
}

test "VM: string split count" {
    const val = try runAndGetLocal(
        \\let parts = "a,b,c".split(",")
        \\let count = parts.len()
        \\
    , 1);
    try std.testing.expectEqual(@as(i64, 3), val.int);
}

test "VM: string split element" {
    const val = try runAndGetLocal(
        \\let parts = "hello world foo".split(" ")
        \\let r = parts[1] == "world"
        \\
    , 1);
    try std.testing.expect(val.bool_val);
}

test "VM: string trim" {
    const val = try runAndGetLocal(
        \\let r = "  hello  ".trim() == "hello"
        \\
    , 0);
    try std.testing.expect(val.bool_val);
}

test "VM: string comparison lt" {
    const val = try runAndGetLocal(
        \\let r = "abc" < "abd"
        \\
    , 0);
    try std.testing.expect(val.bool_val);
}

test "VM: string comparison gte" {
    const val = try runAndGetLocal(
        \\let r = "xyz" >= "abc"
        \\
    , 0);
    try std.testing.expect(val.bool_val);
}

test "VM: string equality" {
    const val = try runAndGetLocal(
        \\let r = "hello" == "hello"
        \\
    , 0);
    try std.testing.expect(val.bool_val);
}

test "VM: string inequality" {
    const val = try runAndGetLocal(
        \\let r = "hello" != "world"
        \\
    , 0);
    try std.testing.expect(val.bool_val);
}

// ---- Phase 3.5: Built-in functions ----

test "VM: math.abs positive" {
    const val = try runAndGetLocal(
        \\let r = math.abs(-42)
        \\
    , 0);
    try std.testing.expectEqual(@as(i64, 42), val.int);
}

test "VM: math.abs float" {
    const val = try runAndGetLocal(
        \\let r = math.abs(-3.14)
        \\
    , 0);
    try std.testing.expectEqual(@as(f64, 3.14), val.float);
}

test "VM: math.min" {
    const val = try runAndGetLocal(
        \\let r = math.min(10, 3)
        \\
    , 0);
    try std.testing.expectEqual(@as(i64, 3), val.int);
}

test "VM: math.max" {
    const val = try runAndGetLocal(
        \\let r = math.max(10, 3)
        \\
    , 0);
    try std.testing.expectEqual(@as(i64, 10), val.int);
}

test "VM: math.floor" {
    const val = try runAndGetLocal(
        \\let r = math.floor(3.7)
        \\
    , 0);
    try std.testing.expectEqual(@as(i64, 3), val.int);
}

test "VM: math.ceil" {
    const val = try runAndGetLocal(
        \\let r = math.ceil(3.2)
        \\
    , 0);
    try std.testing.expectEqual(@as(i64, 4), val.int);
}

test "VM: math.floor int passthrough" {
    const val = try runAndGetLocal(
        \\let r = math.floor(5)
        \\
    , 0);
    try std.testing.expectEqual(@as(i64, 5), val.int);
}

test "VM: math.random returns int in range" {
    const val = try runAndGetLocal(
        \\let r = math.random(1, 10)
        \\let in_range = r >= 1
        \\
    , 1);
    try std.testing.expect(val.bool_val);
}

test "VM: debug.assert passes" {
    const val = try runAndGetLocal(
        \\debug.assert(true)
        \\let r = 42
        \\
    , 0);
    try std.testing.expectEqual(@as(i64, 42), val.int);
}

test "VM: debug.assert with message fails" {
    const result = compileAndRun(
        \\debug.assert(false, "expected true")
        \\
    );
    try std.testing.expectError(error.RuntimeError, result);
}

test "VM: debug.log returns null" {
    const val = try runAndGetLocal(
        \\let r = debug.log("test message")
        \\
    , 0);
    try std.testing.expect(val == .null_val);
}

test "VM: debug.dump returns null" {
    const val = try runAndGetLocal(
        \\let r = debug.dump(42)
        \\
    , 0);
    try std.testing.expect(val == .null_val);
}
