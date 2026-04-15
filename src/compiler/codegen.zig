const std = @import("std");
const ast = @import("ast.zig");
const token_mod = @import("token.zig");
const opcodes = @import("../vm/opcodes.zig");
const diagnostic = @import("diagnostic.zig");

const OpCode = opcodes.OpCode;
const NodeIndex = ast.NodeIndex;
const Span = token_mod.Span;

pub const Constant = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
};

pub const FunctionEntry = struct {
    name_idx: u16,
    arity: u8,
    bytecode_offset: u32,
    local_count: u16,
};

pub const DebugLine = struct {
    bytecode_offset: u32,
    source_line: u32,
};

pub const CompiledModule = struct {
    bytecode: []const u8,
    constants: []const Constant,
    functions: []const FunctionEntry,
    debug_lines: []const DebugLine,

    pub fn serialize(self: *const CompiledModule, writer: anytype) !void {
        // Header
        try writer.writeAll("NERU");
        try writer.writeInt(u16, 1, .little); // version
        try writer.writeInt(u16, 0, .little); // flags

        // Constant pool section
        try writer.writeInt(u32, @intCast(self.constants.len), .little);
        for (self.constants) |c| {
            switch (c) {
                .int => |v| {
                    try writer.writeByte(0x01);
                    try writer.writeInt(i64, v, .little);
                },
                .float => |v| {
                    try writer.writeByte(0x02);
                    const bits: u64 = @bitCast(v);
                    try writer.writeInt(u64, bits, .little);
                },
                .string => |v| {
                    try writer.writeByte(0x03);
                    try writer.writeInt(u32, @intCast(v.len), .little);
                    try writer.writeAll(v);
                },
            }
        }

        // Function table section
        try writer.writeInt(u32, @intCast(self.functions.len), .little);
        for (self.functions) |f| {
            try writer.writeInt(u16, f.name_idx, .little);
            try writer.writeByte(f.arity);
            try writer.writeInt(u32, f.bytecode_offset, .little);
            try writer.writeInt(u16, f.local_count, .little);
        }

        // Bytecode section
        try writer.writeInt(u32, @intCast(self.bytecode.len), .little);
        try writer.writeAll(self.bytecode);

        // Debug info section
        try writer.writeInt(u32, @intCast(self.debug_lines.len), .little);
        for (self.debug_lines) |d| {
            try writer.writeInt(u32, d.bytecode_offset, .little);
            try writer.writeInt(u32, d.source_line, .little);
        }
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !CompiledModule {
        var pos: usize = 0;

        // Header
        if (data.len < 8) return error.InvalidFormat;
        if (!std.mem.eql(u8, data[0..4], "NERU")) return error.InvalidFormat;
        pos = 8; // skip magic + version + flags

        // Constants
        const const_count = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        var constants = try allocator.alloc(Constant, const_count);
        for (0..const_count) |i| {
            const tag = data[pos];
            pos += 1;
            switch (tag) {
                0x01 => {
                    constants[i] = .{ .int = std.mem.readInt(i64, data[pos..][0..8], .little) };
                    pos += 8;
                },
                0x02 => {
                    const bits = std.mem.readInt(u64, data[pos..][0..8], .little);
                    constants[i] = .{ .float = @bitCast(bits) };
                    pos += 8;
                },
                0x03 => {
                    const len = std.mem.readInt(u32, data[pos..][0..4], .little);
                    pos += 4;
                    constants[i] = .{ .string = data[pos .. pos + len] };
                    pos += len;
                },
                else => return error.InvalidFormat,
            }
        }

        // Functions
        const func_count = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        var functions = try allocator.alloc(FunctionEntry, func_count);
        for (0..func_count) |i| {
            functions[i] = .{
                .name_idx = std.mem.readInt(u16, data[pos..][0..2], .little),
                .arity = data[pos + 2],
                .bytecode_offset = std.mem.readInt(u32, data[pos + 3 ..][0..4], .little),
                .local_count = std.mem.readInt(u16, data[pos + 7 ..][0..2], .little),
            };
            pos += 9;
        }

        // Bytecode
        const bc_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        const bytecode = data[pos .. pos + bc_len];
        pos += bc_len;

        // Debug lines
        const debug_count = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        var debug_lines = try allocator.alloc(DebugLine, debug_count);
        for (0..debug_count) |i| {
            debug_lines[i] = .{
                .bytecode_offset = std.mem.readInt(u32, data[pos..][0..4], .little),
                .source_line = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little),
            };
            pos += 8;
        }

        return .{
            .bytecode = bytecode,
            .constants = constants,
            .functions = functions,
            .debug_lines = debug_lines,
        };
    }
};

// ---- Import context for module system ----

pub const ImportContext = struct {
    compiling: std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ImportContext {
        return .{
            .compiling = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ImportContext) void {
        self.compiling.deinit(self.allocator);
    }

    pub fn markCompiling(self: *ImportContext, path: []const u8) !bool {
        const gop = self.compiling.getOrPut(self.allocator, path) catch return error.OutOfMemory;
        return gop.found_existing; // true = circular import
    }

    pub fn unmarkCompiling(self: *ImportContext, path: []const u8) void {
        _ = self.compiling.remove(path);
    }
};

// ---- Local variable tracking ----

const Local = struct {
    name: []const u8,
    depth: u16,
    is_captured: bool = false,
};

const Upvalue = struct {
    index: u16, // local slot in enclosing function
    is_local: bool, // true = captures a local; false = captures an upvalue from parent
};

const LabelPatch = struct {
    patch_pos: u32,
    base: u32,
};

const LoopContext = struct {
    break_patches: std.ArrayList(u32),
    continue_patches: std.ArrayList(u32),
    continue_target: ?u32, // null = use forward-patching; set = direct jump
};

pub const Compiler = struct {
    bytecode: std.ArrayList(u8) = .empty,
    constants: std.ArrayList(Constant) = .empty,
    functions: std.ArrayList(FunctionEntry) = .empty,
    debug_lines: std.ArrayList(DebugLine) = .empty,

    locals: std.ArrayList(Local) = .empty,
    scope_depth: u16,
    max_locals: u32,

    loop_stack: std.ArrayList(LoopContext) = .empty,

    nodes: *const ast.NodeStore,
    diagnostics: *diagnostic.DiagnosticList,
    allocator: std.mem.Allocator,

    // For function compilation
    current_func_local_start: u32,

    // Upvalue tracking for closures
    upvalues: std.ArrayList(Upvalue) = .empty,
    // Stack of parent compiler states for resolving upvalues across nesting
    parent_locals: ?*std.ArrayList(Local) = null,
    parent_local_start: u32 = 0,
    parent_upvalues: ?*std.ArrayList(Upvalue) = null,

    // Compile-time speaker tracking for scenario text lines. Updated by
    // @speaker directives and pushed as the speaker operand of emit_text.
    current_speaker: ?[]const u8 = null,

    // Label table: `#name` → bytecode offset. Populated when a label_def
    // is compiled; used to resolve @goto and #choice targets.
    labels: std.StringHashMapUnmanaged(u32) = .{},

    // Pending jumps keyed by label name. Each patch remembers both the
    // bytecode position of the 4-byte slot to fill and the base IP from
    // which the relative offset is measured (usually patch_pos + 4, but
    // for emit_choice offset tables it is the post-operand IP).
    pending_label_jumps: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(LabelPatch)) = .{},

    // Module system: file path of current source (for relative import resolution)
    source_path: ?[]const u8 = null,

    // Import context: tracks files currently being compiled to detect cycles
    import_context: ?*ImportContext = null,

    pub fn init(
        allocator: std.mem.Allocator,
        nodes: *const ast.NodeStore,
        diagnostics: *diagnostic.DiagnosticList,
    ) Compiler {
        return .{
            .allocator = allocator,
            .nodes = nodes,
            .diagnostics = diagnostics,
            .scope_depth = 0,
            .max_locals = 0,
            .current_func_local_start = 0,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.bytecode.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.debug_lines.deinit(self.allocator);
        self.locals.deinit(self.allocator);
        self.upvalues.deinit(self.allocator);
        for (self.loop_stack.items) |*l| {
            l.break_patches.deinit(self.allocator);
            l.continue_patches.deinit(self.allocator);
        }
        self.loop_stack.deinit(self.allocator);
        self.labels.deinit(self.allocator);
        var it = self.pending_label_jumps.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.pending_label_jumps.deinit(self.allocator);
    }

    pub fn compile(self: *Compiler, program_idx: NodeIndex) !CompiledModule {
        const program = self.nodes.getNode(program_idx).program;

        // Implicit main function entry (function 0)
        const main_name_idx = try self.addStringConstant("__main__");
        self.functions.append(self.allocator, .{
            .name_idx = main_name_idx,
            .arity = 0,
            .bytecode_offset = 0,
            .local_count = 0,
        }) catch return error.OutOfMemory;

        for (program.stmts) |stmt_idx| {
            try self.compileNode(stmt_idx);
        }

        try self.emit(.halt);

        self.reportUnresolvedLabels();

        // Patch main function local count (use max to account for scoped locals)
        self.functions.items[0].local_count = @intCast(self.max_locals);

        return .{
            .bytecode = self.bytecode.items,
            .constants = self.constants.items,
            .functions = self.functions.items,
            .debug_lines = self.debug_lines.items,
        };
    }

    // ---- Node compilation ----

    fn compileNode(self: *Compiler, idx: NodeIndex) anyerror!void {
        const node = self.nodes.getNode(idx);
        switch (node) {
            .let_stmt => |n| try self.compileLetStmt(n),
            .fn_decl => |n| try self.compileFnDecl(n),
            .if_stmt => |n| try self.compileIfStmt(n),
            .for_stmt => |n| try self.compileForStmt(n),
            .while_stmt => |n| try self.compileWhileStmt(n),
            .return_stmt => |n| try self.compileReturnStmt(n),
            .break_stmt => try self.compileBreakStmt(),
            .continue_stmt => try self.compileContinueStmt(),
            .assign_stmt => |n| try self.compileAssignStmt(n),
            .expr_stmt => |n| {
                try self.compileExpr(n.expr);
                try self.emit(.pop);
            },
            .text_line => |n| try self.compileTextLine(n),
            .speaker_directive => |n| try self.compileSpeakerDirective(n),
            .wait_directive => |n| try self.compileWaitDirective(n),
            .clear_directive => |n| try self.compileClearDirective(n),
            .media_directive => |n| try self.compileMediaDirective(n),
            .label_def => |n| try self.defineLabel(n.name, n.span),
            .goto_directive => |n| try self.compileGotoDirective(n),
            .jump_directive => |n| try self.compileJumpDirective(n),
            .choice_block => |n| try self.compileChoiceBlock(n),
            .import_directive => |n| try self.compileImportDirective(n),
            else => {
                // Expression nodes shouldn't appear at statement level
                try self.compileExpr(idx);
            },
        }
    }

    fn compileTextLine(self: *Compiler, line: ast.TextLine) !void {
        self.addDebugLine(line.span.start.line);

        // Push speaker (or null).
        if (self.current_speaker) |s| {
            const idx = try self.addStringConstant(s);
            try self.emitWithU16(.push_const, idx);
        } else {
            try self.emit(.push_null);
        }

        // Build the composite text on the stack.
        if (line.segments.len == 0) {
            const idx = try self.addStringConstant("");
            try self.emitWithU16(.push_const, idx);
        } else {
            try self.compileTextSegment(line.segments[0]);
            for (line.segments[1..]) |seg| {
                try self.compileTextSegment(seg);
                try self.emit(.add);
            }
        }

        try self.emit(.emit_text);
    }

    fn compileTextSegment(self: *Compiler, seg: ast.TextSegment) !void {
        switch (seg) {
            .text => |s| {
                const idx = try self.addStringConstant(s);
                try self.emitWithU16(.push_const, idx);
            },
            .expr => |e| {
                try self.compileExpr(e);
                try self.emit(.to_str);
            },
        }
    }

    fn compileSpeakerDirective(self: *Compiler, d: ast.SpeakerDirective) !void {
        self.addDebugLine(d.span.start.line);
        self.current_speaker = d.name;
        const idx = try self.addStringConstant(d.name);
        try self.emitWithU16(.push_const, idx);
        try self.emit(.emit_speaker);
    }

    fn compileWaitDirective(self: *Compiler, d: ast.WaitDirective) !void {
        self.addDebugLine(d.span.start.line);
        try self.emitWithU32(.emit_wait, d.ms);
    }

    fn compileClearDirective(self: *Compiler, d: ast.ClearDirective) !void {
        self.addDebugLine(d.span.start.line);
        try self.emit(.emit_text_clear);
    }

    fn compileGotoDirective(self: *Compiler, d: ast.GotoDirective) !void {
        self.addDebugLine(d.span.start.line);
        try self.emitJumpToLabel(d.target);
    }

    fn compileJumpDirective(self: *Compiler, d: ast.JumpDirective) !void {
        // Cross-file jumps are scheduled for later phases (see Phase 3.6).
        // Accept the syntax but surface a codegen diagnostic so the user
        // knows it will not execute at runtime yet.
        self.diagnostics.addWarning(.codegen, d.span, "@jump is not yet implemented; execution will halt here");
        try self.emit(.halt);
    }

    fn compileImportDirective(self: *Compiler, d: ast.ImportDirective) !void {
        self.addDebugLine(d.span.start.line);

        // Resolve file path relative to current source
        const resolved_path = self.resolveImportPath(d.filepath) orelse {
            self.diagnostics.addError(.codegen, d.span, "cannot resolve import path");
            return;
        };

        // Check circular imports
        if (self.import_context) |ctx| {
            const is_circular = ctx.markCompiling(resolved_path) catch {
                self.diagnostics.addError(.codegen, d.span, "import tracking failed");
                return;
            };
            if (is_circular) {
                self.diagnostics.addError(.codegen, d.span, "circular import detected");
                return;
            }
        }

        // Read and compile the imported file
        const source = std.fs.cwd().readFileAlloc(self.allocator, resolved_path, 1024 * 1024) catch {
            self.diagnostics.addError(.codegen, d.span, "cannot read imported file");
            if (self.import_context) |ctx| ctx.unmarkCompiling(resolved_path);
            return;
        };

        const lexer_mod = @import("lexer.zig");
        const parser_mod = @import("parser.zig");
        var imp_nodes = ast.NodeStore.init(self.allocator);
        var imp_lexer = lexer_mod.Lexer.init(source, self.diagnostics, lexer_mod.Mode.fromPath(resolved_path));
        var imp_parser = parser_mod.Parser.init(self.allocator, &imp_lexer, &imp_nodes, self.diagnostics);
        const imp_root = imp_parser.parseProgram() catch {
            if (self.import_context) |ctx| ctx.unmarkCompiling(resolved_path);
            return;
        };

        if (self.diagnostics.hasErrors()) {
            if (self.import_context) |ctx| ctx.unmarkCompiling(resolved_path);
            return;
        }

        var imp_compiler = Compiler.init(self.allocator, &imp_nodes, self.diagnostics);
        imp_compiler.source_path = resolved_path;
        imp_compiler.import_context = self.import_context;
        const imp_module = imp_compiler.compile(imp_root) catch {
            if (self.import_context) |ctx| ctx.unmarkCompiling(resolved_path);
            return;
        };

        if (self.import_context) |ctx| ctx.unmarkCompiling(resolved_path);

        if (self.diagnostics.hasErrors()) return;

        // Merge imported functions into current module
        const is_wildcard = std.mem.eql(u8, d.target, "*");

        // Skip function 0 (__main__) of imported module
        for (imp_module.functions[1..]) |imp_func| {
            const fname = imp_module.constants[imp_func.name_idx].string;

            // Skip private functions (starting with _)
            if (fname.len > 0 and fname[0] == '_') continue;

            // For named import, only import the specified function
            if (!is_wildcard and !std.mem.eql(u8, fname, d.target)) continue;

            // Copy function bytecode into current module
            const bytecode_start: u32 = @intCast(self.bytecode.items.len);

            // Emit jump over imported function body
            const jump_over = try self.emitJump(.jump);

            const new_offset: u32 = @intCast(self.bytecode.items.len);

            // Copy bytecode from imported function
            const imp_bc_end = self.findFunctionEnd(imp_module, imp_func);
            self.bytecode.appendSlice(self.allocator, imp_module.bytecode[imp_func.bytecode_offset..imp_bc_end]) catch return error.OutOfMemory;

            // Remap constant references in copied bytecode
            const const_base: u16 = @intCast(self.constants.items.len);
            for (imp_module.constants) |c| {
                self.constants.append(self.allocator, c) catch return error.OutOfMemory;
            }
            self.remapConstants(bytecode_start + 5, const_base, imp_module.bytecode[imp_func.bytecode_offset..imp_bc_end]);

            _ = new_offset;
            self.patchJump(jump_over);

            // Register function
            const name_idx = try self.addStringConstant(fname);
            const func_id: u16 = @intCast(self.functions.items.len);
            self.functions.append(self.allocator, .{
                .name_idx = name_idx,
                .arity = imp_func.arity,
                .bytecode_offset = bytecode_start + 5, // after jump_over
                .local_count = imp_func.local_count,
            }) catch return error.OutOfMemory;

            // Store as local variable
            try self.emitWithU16(.push_function, func_id);
            const slot = try self.declareLocal(fname);
            try self.emitWithU16(.store_local, slot);
        }

        if (!is_wildcard) {
            // Check if the named function was found
            var found = false;
            for (imp_module.functions[1..]) |imp_func| {
                const fname = imp_module.constants[imp_func.name_idx].string;
                if (std.mem.eql(u8, fname, d.target)) {
                    if (fname.len > 0 and fname[0] == '_') {
                        self.diagnostics.addError(.codegen, d.span, "cannot import private function");
                    }
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.diagnostics.addError(.codegen, d.span, "function not found in imported module");
            }
        }
    }

    fn resolveImportPath(self: *const Compiler, filepath: []const u8) ?[]const u8 {
        if (self.source_path) |sp| {
            // Resolve relative to the directory of the current source file
            const dir = std.fs.path.dirname(sp) orelse ".";
            return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filepath }) catch return null;
        }
        // No source path context — use filepath as-is
        return filepath;
    }

    fn findFunctionEnd(self: *const Compiler, module: CompiledModule, func: FunctionEntry) u32 {
        _ = self;
        // Find the end of the function's bytecode by looking for the next function
        // or the end of the module's bytecode
        var closest_end: u32 = @intCast(module.bytecode.len);
        for (module.functions) |other| {
            if (other.bytecode_offset > func.bytecode_offset and other.bytecode_offset < closest_end) {
                closest_end = other.bytecode_offset;
            }
        }
        return closest_end;
    }

    fn remapConstants(self: *Compiler, start: u32, const_base: u16, original_bc: []const u8) void {
        // Walk through copied bytecode and remap push_const operands
        var ip: u32 = 0;
        while (ip < original_bc.len) {
            const op: OpCode = @enumFromInt(original_bc[ip]);
            ip += 1;
            switch (op) {
                .push_const, .load_member, .store_member, .call_method, .call_builtin => {
                    // These have u16 constant indices that need remapping
                    const abs_pos = start + ip;
                    const old_idx = std.mem.readInt(u16, self.bytecode.items[abs_pos..][0..2], .little);
                    const new_idx = old_idx + const_base;
                    const bytes = std.mem.toBytes(std.mem.nativeToLittle(u16, new_idx));
                    @memcpy(self.bytecode.items[abs_pos..][0..2], &bytes);
                    ip += op.operandSize();
                },
                else => {
                    ip += op.operandSize();
                },
            }
        }
    }

    fn compileChoiceBlock(self: *Compiler, d: ast.ChoiceBlock) !void {
        self.addDebugLine(d.span.start.line);

        if (d.items.len > 255) {
            self.diagnostics.addError(.codegen, d.span, "#choice supports at most 255 items");
            return error.RuntimeError;
        }
        const count: u8 = @intCast(d.items.len);

        // Push each item as (visible_flag, label, target_name).
        for (d.items) |item| {
            if (item.condition) |cond| {
                try self.compileExpr(cond);
            } else {
                try self.emit(.push_true);
            }
            const label_idx = try self.addStringConstant(item.label);
            try self.emitWithU16(.push_const, label_idx);
            const target_idx = try self.addStringConstant(item.target);
            try self.emitWithU16(.push_const, target_idx);
        }

        try self.emit(.emit_choice);
        self.bytecode.append(self.allocator, count) catch return error.OutOfMemory;

        // Reserve count × i32 for the offset table. Each slot is patched when
        // its target label is defined (or immediately if already known).
        const offsets_start: u32 = @intCast(self.bytecode.items.len);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            self.bytecode.appendSlice(self.allocator, &[4]u8{ 0, 0, 0, 0 }) catch return error.OutOfMemory;
        }
        const base: u32 = offsets_start + count * 4;

        for (d.items, 0..) |item, idx| {
            const patch_pos: u32 = offsets_start + @as(u32, @intCast(idx)) * 4;
            try self.recordLabelReference(item.target, .{ .patch_pos = patch_pos, .base = base });
        }
    }

    fn compileMediaDirective(self: *Compiler, d: ast.MediaDirective) !void {
        self.addDebugLine(d.span.start.line);

        // Push primary (image / character / track / sound / kind).
        if (d.primary) |p| {
            const idx = try self.addStringConstant(p);
            try self.emitWithU16(.push_const, idx);
        }

        // Push each option as (key_string, value).
        for (d.options) |opt| {
            const key_idx = try self.addStringConstant(opt.key);
            try self.emitWithU16(.push_const, key_idx);
            try self.pushOptionValue(opt.value);
        }

        if (d.options.len > 255) {
            self.diagnostics.addError(.codegen, d.span, "too many directive options (max 255)");
            return error.RuntimeError;
        }

        // emit_directive: [kind: u8][arg_count: u8]
        try self.emit(.emit_directive);
        self.bytecode.append(self.allocator, @intFromEnum(d.kind)) catch return error.OutOfMemory;
        self.bytecode.append(self.allocator, @intCast(d.options.len)) catch return error.OutOfMemory;
    }

    fn pushOptionValue(self: *Compiler, v: ast.OptionValue) !void {
        switch (v) {
            .int => |n| {
                const idx = try self.addConstant(.{ .int = n });
                try self.emitWithU16(.push_const, idx);
            },
            .float => |f| {
                const idx = try self.addConstant(.{ .float = f });
                try self.emitWithU16(.push_const, idx);
            },
            .string, .ident => |s| {
                const idx = try self.addStringConstant(s);
                try self.emitWithU16(.push_const, idx);
            },
            .bool_val => |b| try self.emit(if (b) .push_true else .push_false),
        }
    }

    fn compileLetStmt(self: *Compiler, stmt: ast.LetStmt) !void {
        self.addDebugLine(stmt.span.start.line);
        try self.compileExpr(stmt.value);
        const slot = try self.declareLocal(stmt.name);
        try self.emitWithU16(.store_local, slot);
    }

    fn compileFnDecl(self: *Compiler, decl: ast.FnDecl) !void {
        self.addDebugLine(decl.span.start.line);

        // Jump over function body
        const jump_over = try self.emitJump(.jump);

        const func_offset: u32 = @intCast(self.bytecode.items.len);
        const name_idx = try self.addStringConstant(decl.name);

        // Pre-register function so recursive calls can find it
        const func_id: u16 = @intCast(self.functions.items.len);
        self.functions.append(self.allocator, .{
            .name_idx = name_idx,
            .arity = @intCast(decl.params.len),
            .bytecode_offset = func_offset,
            .local_count = 0, // patched later
        }) catch return error.OutOfMemory;

        // Save compiler state
        const saved_local_start = self.current_func_local_start;
        const saved_local_count = self.locals.items.len;
        const saved_depth = self.scope_depth;
        const saved_max_locals = self.max_locals;
        const saved_upvalues = self.upvalues;
        const saved_parent_locals = self.parent_locals;
        const saved_parent_local_start = self.parent_local_start;
        const saved_parent_upvalues = self.parent_upvalues;

        // Set up parent references for upvalue resolution
        self.parent_locals = &self.locals;
        self.parent_local_start = self.current_func_local_start;
        self.parent_upvalues = &self.upvalues;

        self.current_func_local_start = @intCast(self.locals.items.len);
        self.scope_depth = 0;
        self.max_locals = 0;
        self.upvalues = .empty;

        // Declare parameters as locals
        for (decl.params) |param| {
            _ = try self.declareLocal(param);
        }

        // Compile body
        self.beginScope();
        for (decl.body) |stmt_idx| {
            try self.compileNode(stmt_idx);
        }
        // Implicit return null
        try self.emit(.push_null);
        try self.emit(.ret);
        self.endScope();

        // Patch function local count
        self.functions.items[func_id].local_count = @intCast(self.max_locals);

        // Capture upvalue list before restoring state
        const fn_upvalues = self.upvalues;

        // Restore compiler state
        self.locals.shrinkRetainingCapacity(saved_local_count);
        self.current_func_local_start = saved_local_start;
        self.scope_depth = saved_depth;
        self.max_locals = saved_max_locals;
        self.upvalues = saved_upvalues;
        self.parent_locals = saved_parent_locals;
        self.parent_local_start = saved_parent_local_start;
        self.parent_upvalues = saved_parent_upvalues;

        self.patchJump(jump_over);

        // Emit closure or plain function depending on whether upvalues were captured
        if (fn_upvalues.items.len > 0) {
            try self.emitMakeClosure(func_id, fn_upvalues.items);
        } else {
            try self.emitWithU16(.push_function, func_id);
        }
        const slot = try self.declareLocal(decl.name);
        try self.emitWithU16(.store_local, slot);
    }

    fn compileIfStmt(self: *Compiler, stmt: ast.IfStmt) !void {
        self.addDebugLine(stmt.span.start.line);

        try self.compileExpr(stmt.condition);
        const else_jump = try self.emitJump(.jump_if_not);

        // Then body
        self.beginScope();
        for (stmt.then_body) |s| try self.compileNode(s);
        self.endScope();

        // Jump over else
        const end_jump = try self.emitJump(.jump);
        self.patchJump(else_jump);

        // Else-if clauses
        var elif_end_jumps: std.ArrayList(u32) = .empty;
        defer elif_end_jumps.deinit(self.allocator);

        for (stmt.else_if_clauses) |clause| {
            try self.compileExpr(clause.condition);
            const next_jump = try self.emitJump(.jump_if_not);

            self.beginScope();
            for (clause.body) |s| try self.compileNode(s);
            self.endScope();

            elif_end_jumps.append(self.allocator, try self.emitJump(.jump)) catch return error.OutOfMemory;
            self.patchJump(next_jump);
        }

        // Else body
        if (stmt.else_body) |else_body| {
            self.beginScope();
            for (else_body) |s| try self.compileNode(s);
            self.endScope();
        }

        // Patch all end jumps
        self.patchJump(end_jump);
        for (elif_end_jumps.items) |j| self.patchJump(j);
    }

    fn compileForStmt(self: *Compiler, stmt: ast.ForStmt) !void {
        self.addDebugLine(stmt.span.start.line);

        const iterable_node = self.nodes.getNode(stmt.iterable);
        if (iterable_node == .range_expr) {
            try self.compileRangeFor(stmt, iterable_node.range_expr);
        } else {
            try self.compileArrayFor(stmt);
        }
    }

    fn compileRangeFor(self: *Compiler, stmt: ast.ForStmt, range: ast.RangeExpr) !void {
        self.beginScope();

        // Compile start value and declare iterator
        try self.compileExpr(range.start);
        const iter_slot = try self.declareLocal(stmt.iterator_name);
        try self.emitWithU16(.store_local, iter_slot);

        // Compile end value and store in a hidden local
        try self.compileExpr(range.end);
        const end_slot = try self.declareLocal("__range_end__");
        try self.emitWithU16(.store_local, end_slot);

        // Loop start
        const loop_start: u32 = @intCast(self.bytecode.items.len);

        // Push loop context (continue uses forward-patching → targets increment)
        self.loop_stack.append(self.allocator, .{
            .break_patches = .empty,
            .continue_patches = .empty,
            .continue_target = null, // patched to increment section below
        }) catch return error.OutOfMemory;

        // Condition: iter < end
        try self.emitWithU16(.load_local, iter_slot);
        try self.emitWithU16(.load_local, end_slot);
        try self.emit(.lt);
        const exit_jump = try self.emitJump(.jump_if_not);

        // Body
        for (stmt.body) |s| try self.compileNode(s);

        // Increment section (continue target)
        const continue_target: u32 = @intCast(self.bytecode.items.len);

        // Increment iterator: iter = iter + 1
        try self.emitWithU16(.load_local, iter_slot);
        const one_const = try self.addConstant(.{ .int = 1 });
        try self.emitWithU16(.push_const, one_const);
        try self.emit(.add);
        try self.emitWithU16(.store_local, iter_slot);

        // Jump back
        try self.emitLoop(loop_start);
        self.patchJump(exit_jump);

        // Patch break and continue jumps
        var loop_ctx = self.loop_stack.pop().?;
        for (loop_ctx.break_patches.items) |bp| self.patchJump(bp);
        loop_ctx.break_patches.deinit(self.allocator);
        for (loop_ctx.continue_patches.items) |cp| self.patchForwardJump(cp, continue_target);
        loop_ctx.continue_patches.deinit(self.allocator);

        self.endScope();
    }

    fn compileArrayFor(self: *Compiler, stmt: ast.ForStmt) !void {
        self.beginScope();

        // Evaluate iterable and store in hidden local
        try self.compileExpr(stmt.iterable);
        const arr_slot = try self.declareLocal("__for_arr__");
        try self.emitWithU16(.store_local, arr_slot);

        // Index counter = 0
        const zero_const = try self.addConstant(.{ .int = 0 });
        try self.emitWithU16(.push_const, zero_const);
        const idx_slot = try self.declareLocal("__for_idx__");
        try self.emitWithU16(.store_local, idx_slot);

        // Declare the iterator variable (assigned each iteration)
        try self.emit(.push_null);
        const iter_slot = try self.declareLocal(stmt.iterator_name);
        try self.emitWithU16(.store_local, iter_slot);

        // Loop start
        const loop_start: u32 = @intCast(self.bytecode.items.len);

        // Push loop context (continue uses forward-patching → targets increment)
        self.loop_stack.append(self.allocator, .{
            .break_patches = .empty,
            .continue_patches = .empty,
            .continue_target = null, // patched to increment section below
        }) catch return error.OutOfMemory;

        // Condition: idx < arr.len()
        try self.emitWithU16(.load_local, idx_slot);
        try self.emitWithU16(.load_local, arr_slot);
        const len_name = try self.addStringConstant("len");
        try self.emitWithU16(.call_method, len_name);
        self.bytecode.append(self.allocator, 0) catch return error.OutOfMemory; // 0 args
        try self.emit(.lt);
        const exit_jump = try self.emitJump(.jump_if_not);

        // Load current element: item = arr[idx]
        try self.emitWithU16(.load_local, arr_slot);
        try self.emitWithU16(.load_local, idx_slot);
        try self.emit(.load_index);
        try self.emitWithU16(.store_local, iter_slot);

        // Body
        for (stmt.body) |s| try self.compileNode(s);

        // Increment section (continue target)
        const continue_target: u32 = @intCast(self.bytecode.items.len);

        // idx = idx + 1
        try self.emitWithU16(.load_local, idx_slot);
        const one_const = try self.addConstant(.{ .int = 1 });
        try self.emitWithU16(.push_const, one_const);
        try self.emit(.add);
        try self.emitWithU16(.store_local, idx_slot);

        // Jump back to condition
        try self.emitLoop(loop_start);
        self.patchJump(exit_jump);

        // Patch break and continue jumps
        var loop_ctx = self.loop_stack.pop().?;
        for (loop_ctx.break_patches.items) |bp| self.patchJump(bp);
        loop_ctx.break_patches.deinit(self.allocator);
        for (loop_ctx.continue_patches.items) |cp| self.patchForwardJump(cp, continue_target);
        loop_ctx.continue_patches.deinit(self.allocator);

        self.endScope();
    }

    fn compileWhileStmt(self: *Compiler, stmt: ast.WhileStmt) !void {
        self.addDebugLine(stmt.span.start.line);

        const loop_start: u32 = @intCast(self.bytecode.items.len);

        self.loop_stack.append(self.allocator, .{
            .break_patches = .empty,
            .continue_patches = .empty,
            .continue_target = loop_start, // while: continue goes to condition
        }) catch return error.OutOfMemory;

        try self.compileExpr(stmt.condition);
        const exit_jump = try self.emitJump(.jump_if_not);

        self.beginScope();
        for (stmt.body) |s| try self.compileNode(s);
        self.endScope();

        try self.emitLoop(loop_start);
        self.patchJump(exit_jump);

        var loop_ctx = self.loop_stack.pop().?;
        for (loop_ctx.break_patches.items) |bp| self.patchJump(bp);
        loop_ctx.break_patches.deinit(self.allocator);
        loop_ctx.continue_patches.deinit(self.allocator);
    }

    fn compileReturnStmt(self: *Compiler, stmt: ast.ReturnStmt) !void {
        self.addDebugLine(stmt.span.start.line);
        if (stmt.value) |val| {
            try self.compileExpr(val);
        } else {
            try self.emit(.push_null);
        }
        try self.emit(.ret);
    }

    fn compileBreakStmt(self: *Compiler) !void {
        if (self.loop_stack.items.len == 0) {
            self.diagnostics.addError(.codegen, .{
                .start = .{ .line = 0, .column = 0, .offset = 0 },
                .end = .{ .line = 0, .column = 0, .offset = 0 },
            }, "'break' outside of loop");
            return;
        }
        const jump = try self.emitJump(.jump);
        const loop_ctx = &self.loop_stack.items[self.loop_stack.items.len - 1];
        loop_ctx.break_patches.append(self.allocator, jump) catch return error.OutOfMemory;
    }

    fn compileContinueStmt(self: *Compiler) !void {
        if (self.loop_stack.items.len == 0) {
            self.diagnostics.addError(.codegen, .{
                .start = .{ .line = 0, .column = 0, .offset = 0 },
                .end = .{ .line = 0, .column = 0, .offset = 0 },
            }, "'continue' outside of loop");
            return;
        }
        const loop_ctx = &self.loop_stack.items[self.loop_stack.items.len - 1];
        if (loop_ctx.continue_target) |target| {
            try self.emitLoop(target);
        } else {
            // Forward-patch: target not yet known
            const jump = try self.emitJump(.jump);
            loop_ctx.continue_patches.append(self.allocator, jump) catch return error.OutOfMemory;
        }
    }

    fn compileAssignStmt(self: *Compiler, stmt: ast.AssignStmt) !void {
        self.addDebugLine(stmt.span.start.line);

        const target = self.nodes.getNode(stmt.target);

        if (stmt.op != .assign) {
            // Compound assignment: load target first
            try self.compileExpr(stmt.target);
            try self.compileExpr(stmt.value);
            switch (stmt.op) {
                .plus_assign => try self.emit(.add),
                .minus_assign => try self.emit(.sub),
                .star_assign => try self.emit(.mul),
                .slash_assign => try self.emit(.div),
                .percent_assign => try self.emit(.mod),
                .assign => unreachable,
            }
        } else {
            try self.compileExpr(stmt.value);
        }

        // Store to target
        switch (target) {
            .identifier_expr => |id| {
                if (self.resolveLocal(id.name)) |slot| {
                    try self.emitWithU16(.store_local, slot);
                } else if (self.resolveUpvalue(id.name)) |uv_idx| {
                    try self.emitWithU16(.store_upvalue, uv_idx);
                } else {
                    self.diagnostics.addError(.codegen, stmt.span, "undefined variable");
                }
            },
            .member_expr => |mem| {
                try self.compileExpr(mem.object);
                // Swap: value is below object on stack, we need object then value
                // Actually we need: compile value, compile object, store_member
                // Let's restructure: object is on stack, value is below
                const name_idx = try self.addStringConstant(mem.member);
                try self.emitWithU16(.store_member, name_idx);
            },
            .index_expr => |idx| {
                try self.compileExpr(idx.object);
                try self.compileExpr(idx.index);
                try self.emit(.store_index);
            },
            else => {
                self.diagnostics.addError(.codegen, stmt.span, "invalid assignment target");
            },
        }
    }

    // ---- Expression compilation ----

    fn compileExpr(self: *Compiler, idx: NodeIndex) anyerror!void {
        const node = self.nodes.getNode(idx);
        switch (node) {
            .literal_expr => |n| try self.compileLiteral(n),
            .identifier_expr => |n| try self.compileIdentifier(n),
            .binary_expr => |n| try self.compileBinary(n),
            .unary_expr => |n| try self.compileUnary(n),
            .call_expr => |n| try self.compileCall(n),
            .index_expr => |n| try self.compileIndex(n),
            .member_expr => |n| try self.compileMember(n),
            .grouped_expr => |n| try self.compileExpr(n.inner),
            .array_expr => |n| try self.compileArray(n),
            .map_expr => |n| try self.compileMap(n),
            .range_expr => |n| {
                // Range outside of for: compile as two values (start, end)
                try self.compileExpr(n.start);
                try self.compileExpr(n.end);
            },
            else => {
                self.diagnostics.addError(.codegen, node.span(), "unexpected node in expression position");
            },
        }
    }

    fn compileLiteral(self: *Compiler, lit: ast.LiteralExpr) !void {
        self.addDebugLine(lit.span.start.line);
        switch (lit.value) {
            .int => |v| {
                const idx = try self.addConstant(.{ .int = v });
                try self.emitWithU16(.push_const, idx);
            },
            .float => |v| {
                const idx = try self.addConstant(.{ .float = v });
                try self.emitWithU16(.push_const, idx);
            },
            .string => |v| {
                const idx = try self.addStringConstant(v);
                try self.emitWithU16(.push_const, idx);
            },
            .bool_val => |v| {
                if (v) try self.emit(.push_true) else try self.emit(.push_false);
            },
            .null_val => try self.emit(.push_null),
        }
    }

    fn compileIdentifier(self: *Compiler, id: ast.IdentifierExpr) !void {
        if (self.resolveLocal(id.name)) |slot| {
            try self.emitWithU16(.load_local, slot);
        } else if (self.resolveUpvalue(id.name)) |uv_idx| {
            try self.emitWithU16(.load_upvalue, uv_idx);
        } else {
            self.diagnostics.addError(.codegen, id.span, "undefined variable");
        }
    }

    fn compileBinary(self: *Compiler, expr: ast.BinaryExpr) !void {
        // Short-circuit for && and ||
        if (expr.op == .@"and") {
            try self.compileExpr(expr.left);
            const skip = try self.emitJump(.jump_if_not);
            try self.compileExpr(expr.right);
            const end = try self.emitJump(.jump);
            self.patchJump(skip);
            try self.emit(.push_false);
            self.patchJump(end);
            return;
        }
        if (expr.op == .@"or") {
            try self.compileExpr(expr.left);
            const skip = try self.emitJump(.jump_if);
            try self.compileExpr(expr.right);
            const end = try self.emitJump(.jump);
            self.patchJump(skip);
            try self.emit(.push_true);
            self.patchJump(end);
            return;
        }

        try self.compileExpr(expr.left);
        try self.compileExpr(expr.right);

        switch (expr.op) {
            .add => try self.emit(.add),
            .sub => try self.emit(.sub),
            .mul => try self.emit(.mul),
            .div => try self.emit(.div),
            .mod => try self.emit(.mod),
            .eq => try self.emit(.eq),
            .neq => try self.emit(.neq),
            .lt => try self.emit(.lt),
            .gt => try self.emit(.gt),
            .lte => try self.emit(.lte),
            .gte => try self.emit(.gte),
            .@"and", .@"or" => unreachable,
        }
    }

    fn compileUnary(self: *Compiler, expr: ast.UnaryExpr) !void {
        try self.compileExpr(expr.operand);
        switch (expr.op) {
            .negate => try self.emit(.neg),
            .not => try self.emit(.op_not),
        }
    }

    const builtin_modules = [_][]const u8{ "math", "debug" };

    fn isBuiltinModule(name: []const u8) bool {
        for (builtin_modules) |m| {
            if (std.mem.eql(u8, m, name)) return true;
        }
        return false;
    }

    fn compileCall(self: *Compiler, expr: ast.CallExpr) !void {
        const callee = self.nodes.getNode(expr.callee);

        // Method call: obj.method(args...)
        if (callee == .member_expr) {
            const mem = callee.member_expr;

            // Check for built-in module calls: math.abs(x), debug.log(x)
            const obj_node = self.nodes.getNode(mem.object);
            if (obj_node == .identifier_expr) {
                if (isBuiltinModule(obj_node.identifier_expr.name)) {
                    // Encode as "module.method" in constant pool
                    const full_name = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{
                        obj_node.identifier_expr.name, mem.member,
                    }) catch return error.OutOfMemory;
                    const name_idx = try self.addStringConstant(full_name);
                    for (expr.args) |arg| {
                        try self.compileExpr(arg);
                    }
                    try self.emitWithU16(.call_builtin, name_idx);
                    self.bytecode.append(self.allocator, @intCast(expr.args.len)) catch return error.OutOfMemory;
                    return;
                }
            }

            // Regular method call: obj.method(args...)
            try self.compileExpr(mem.object);
            // Push arguments
            for (expr.args) |arg| {
                try self.compileExpr(arg);
            }
            const name_idx = try self.addStringConstant(mem.member);
            try self.emitWithU16(.call_method, name_idx);
            self.bytecode.append(self.allocator, @intCast(expr.args.len)) catch return error.OutOfMemory;
            return;
        }

        // Try static function table lookup for direct identifier calls
        if (callee == .identifier_expr) {
            const name = callee.identifier_expr.name;

            // Search function table for the name (static call)
            var func_id: ?u16 = null;
            for (self.functions.items, 0..) |f, i| {
                const fname = self.constants.items[f.name_idx].string;
                if (std.mem.eql(u8, fname, name)) {
                    func_id = @intCast(i);
                }
            }

            if (func_id) |fid| {
                // Push arguments
                for (expr.args) |arg| {
                    try self.compileExpr(arg);
                }
                try self.emitCall(fid, @intCast(expr.args.len));
                return;
            }

            // Not in function table — try as a local variable holding a function value
            if (self.resolveLocal(name) != null) {
                try self.compileExpr(expr.callee); // pushes function value
                for (expr.args) |arg| {
                    try self.compileExpr(arg);
                }
                try self.emitCallValue(@intCast(expr.args.len));
                return;
            }

            self.diagnostics.addError(.codegen, expr.span, "undefined function or variable");
            return;
        }

        // Arbitrary expression as callee (e.g., arr[0](), get_fn()())
        try self.compileExpr(expr.callee);
        for (expr.args) |arg| {
            try self.compileExpr(arg);
        }
        try self.emitCallValue(@intCast(expr.args.len));
    }

    fn compileIndex(self: *Compiler, expr: ast.IndexExpr) !void {
        try self.compileExpr(expr.object);
        try self.compileExpr(expr.index);
        try self.emit(.load_index);
    }

    fn compileMember(self: *Compiler, expr: ast.MemberExpr) !void {
        try self.compileExpr(expr.object);
        const name_idx = try self.addStringConstant(expr.member);
        try self.emitWithU16(.load_member, name_idx);
    }

    fn compileArray(self: *Compiler, expr: ast.ArrayExpr) !void {
        for (expr.elements) |elem| {
            try self.compileExpr(elem);
        }
        try self.emitWithU16(.make_array, @intCast(expr.elements.len));
    }

    fn compileMap(self: *Compiler, expr: ast.MapExpr) !void {
        for (expr.entries) |entry| {
            try self.compileExpr(entry.key);
            try self.compileExpr(entry.value);
        }
        try self.emitWithU16(.make_map, @intCast(expr.entries.len));
    }

    // ---- Bytecode emission ----

    fn emit(self: *Compiler, op: OpCode) !void {
        self.bytecode.append(self.allocator, @intFromEnum(op)) catch return error.OutOfMemory;
    }

    fn emitWithU16(self: *Compiler, op: OpCode, operand: u16) !void {
        try self.emit(op);
        const bytes = std.mem.toBytes(std.mem.nativeToLittle(u16, operand));
        self.bytecode.appendSlice(self.allocator, &bytes) catch return error.OutOfMemory;
    }

    fn emitWithU32(self: *Compiler, op: OpCode, operand: u32) !void {
        try self.emit(op);
        const bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, operand));
        self.bytecode.appendSlice(self.allocator, &bytes) catch return error.OutOfMemory;
    }

    fn emitCall(self: *Compiler, func_id: u16, argc: u8) !void {
        try self.emit(.call);
        const id_bytes = std.mem.toBytes(std.mem.nativeToLittle(u16, func_id));
        self.bytecode.appendSlice(self.allocator, &id_bytes) catch return error.OutOfMemory;
        self.bytecode.append(self.allocator, argc) catch return error.OutOfMemory;
    }

    fn emitCallValue(self: *Compiler, argc: u8) !void {
        try self.emit(.call_value);
        self.bytecode.append(self.allocator, argc) catch return error.OutOfMemory;
    }

    fn emitJump(self: *Compiler, op: OpCode) !u32 {
        try self.emit(op);
        const patch_pos: u32 = @intCast(self.bytecode.items.len);
        // Placeholder for i32 offset
        self.bytecode.appendSlice(self.allocator, &[4]u8{ 0, 0, 0, 0 }) catch return error.OutOfMemory;
        return patch_pos;
    }

    fn patchJump(self: *Compiler, patch_pos: u32) void {
        const current: i32 = @intCast(self.bytecode.items.len);
        const target: i32 = @intCast(patch_pos + 4); // offset is relative to after the operand
        const offset: i32 = current - target;
        const bytes = std.mem.toBytes(std.mem.nativeToLittle(i32, offset));
        @memcpy(self.bytecode.items[patch_pos..][0..4], &bytes);
    }

    fn patchForwardJump(self: *Compiler, patch_pos: u32, target_addr: u32) void {
        const base: i32 = @intCast(patch_pos + 4);
        const target: i32 = @intCast(target_addr);
        const offset: i32 = target - base;
        const bytes = std.mem.toBytes(std.mem.nativeToLittle(i32, offset));
        @memcpy(self.bytecode.items[patch_pos..][0..4], &bytes);
    }

    // ---- Label / flow control helpers ----

    /// Record that `name` refers to the current bytecode position. Patches any
    /// pending jumps that referenced the label before it was defined.
    fn defineLabel(self: *Compiler, name: []const u8, span: Span) !void {
        const offset: u32 = @intCast(self.bytecode.items.len);
        const gop = self.labels.getOrPut(self.allocator, name) catch return error.OutOfMemory;
        if (gop.found_existing) {
            self.diagnostics.addError(.codegen, span, "duplicate label definition");
            return;
        }
        gop.value_ptr.* = offset;

        if (self.pending_label_jumps.getPtr(name)) |list| {
            for (list.items) |patch| {
                self.writeRelativeOffsetAt(patch.patch_pos, patch.base, offset);
            }
            list.deinit(self.allocator);
            _ = self.pending_label_jumps.remove(name);
        }
    }

    /// Emit an unconditional jump to `target_name`. If the label is already
    /// defined the offset is written directly; otherwise a placeholder is
    /// recorded for later patching.
    fn emitJumpToLabel(self: *Compiler, target_name: []const u8) !void {
        try self.emit(.jump);
        const patch_pos: u32 = @intCast(self.bytecode.items.len);
        self.bytecode.appendSlice(self.allocator, &[4]u8{ 0, 0, 0, 0 }) catch return error.OutOfMemory;
        try self.recordLabelReference(target_name, .{ .patch_pos = patch_pos, .base = patch_pos + 4 });
    }

    fn recordLabelReference(self: *Compiler, name: []const u8, patch: LabelPatch) !void {
        if (self.labels.get(name)) |target| {
            self.writeRelativeOffsetAt(patch.patch_pos, patch.base, target);
            return;
        }
        const gop = self.pending_label_jumps.getOrPut(self.allocator, name) catch return error.OutOfMemory;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.append(self.allocator, patch) catch return error.OutOfMemory;
    }

    fn writeRelativeOffsetAt(self: *Compiler, patch_pos: u32, base: u32, target: u32) void {
        const offset: i32 = @as(i32, @intCast(target)) - @as(i32, @intCast(base));
        const bytes = std.mem.toBytes(std.mem.nativeToLittle(i32, offset));
        @memcpy(self.bytecode.items[patch_pos..][0..4], &bytes);
    }

    fn reportUnresolvedLabels(self: *Compiler) void {
        var it = self.pending_label_jumps.keyIterator();
        while (it.next()) |name_ptr| {
            self.diagnostics.addError(.codegen, .{
                .start = .{ .line = 0, .column = 0, .offset = 0 },
                .end = .{ .line = 0, .column = 0, .offset = 0 },
            }, "unresolved label reference");
            _ = name_ptr; // name is in diagnostic-arena if we want
        }
    }

    fn emitLoop(self: *Compiler, loop_start: u32) !void {
        try self.emit(.jump);
        const current: i32 = @intCast(self.bytecode.items.len + 4); // after operand
        const target: i32 = @intCast(loop_start);
        const offset: i32 = target - current;
        const bytes = std.mem.toBytes(std.mem.nativeToLittle(i32, offset));
        self.bytecode.appendSlice(self.allocator, &bytes) catch return error.OutOfMemory;
    }

    // ---- Constant pool ----

    fn addConstant(self: *Compiler, value: Constant) !u16 {
        // Dedup: check if constant already exists
        for (self.constants.items, 0..) |c, i| {
            if (constantEql(c, value)) return @intCast(i);
        }
        const idx: u16 = @intCast(self.constants.items.len);
        self.constants.append(self.allocator, value) catch return error.OutOfMemory;
        return idx;
    }

    fn addStringConstant(self: *Compiler, s: []const u8) !u16 {
        return self.addConstant(.{ .string = s });
    }

    fn constantEql(a: Constant, b: Constant) bool {
        const a_tag: @typeInfo(Constant).@"union".tag_type.? = a;
        const b_tag: @typeInfo(Constant).@"union".tag_type.? = b;
        if (a_tag != b_tag) return false;
        return switch (a) {
            .int => |v| v == b.int,
            .float => |v| v == b.float,
            .string => |v| std.mem.eql(u8, v, b.string),
        };
    }

    // ---- Scope management ----

    fn beginScope(self: *Compiler) void {
        self.scope_depth += 1;
    }

    fn endScope(self: *Compiler) void {
        self.scope_depth -= 1;
        // Pop locals that are out of scope
        while (self.locals.items.len > self.current_func_local_start) {
            const last = self.locals.items[self.locals.items.len - 1];
            if (last.depth <= self.scope_depth) break;
            self.locals.items.len -= 1;
        }
    }

    fn declareLocal(self: *Compiler, name: []const u8) !u16 {
        self.locals.append(self.allocator, .{
            .name = name,
            .depth = self.scope_depth,
        }) catch return error.OutOfMemory;
        const relative_slot: u16 = @intCast(self.locals.items.len - 1 - self.current_func_local_start);
        const current_count: u32 = @as(u32, relative_slot) + 1;
        if (current_count > self.max_locals) {
            self.max_locals = current_count;
        }
        return relative_slot;
    }

    fn resolveLocal(self: *const Compiler, name: []const u8) ?u16 {
        if (self.locals.items.len == 0) return null;
        var i: usize = self.locals.items.len;
        while (i > self.current_func_local_start) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) {
                return @intCast(i - self.current_func_local_start);
            }
        }
        return null;
    }

    fn resolveUpvalue(self: *Compiler, name: []const u8) ?u16 {
        const pl = self.parent_locals orelse return null;

        // Try to capture from the immediately enclosing function's locals
        var i: usize = pl.items.len;
        while (i > self.parent_local_start) {
            i -= 1;
            if (std.mem.eql(u8, pl.items[i].name, name)) {
                pl.items[i].is_captured = true;
                return self.addUpvalue(@intCast(i - self.parent_local_start), true);
            }
        }

        return null;
    }

    fn addUpvalue(self: *Compiler, index: u16, is_local: bool) ?u16 {
        // Check for duplicate
        for (self.upvalues.items, 0..) |uv, i| {
            if (uv.index == index and uv.is_local == is_local) {
                return @intCast(i);
            }
        }
        self.upvalues.append(self.allocator, .{
            .index = index,
            .is_local = is_local,
        }) catch return null;
        return @intCast(self.upvalues.items.len - 1);
    }

    fn emitMakeClosure(self: *Compiler, func_id: u16, upvalue_list: []const Upvalue) !void {
        try self.emit(.make_closure);
        const fid_bytes = std.mem.toBytes(std.mem.nativeToLittle(u16, func_id));
        self.bytecode.appendSlice(self.allocator, &fid_bytes) catch return error.OutOfMemory;
        const uv_count: u16 = @intCast(upvalue_list.len);
        const uv_bytes = std.mem.toBytes(std.mem.nativeToLittle(u16, uv_count));
        self.bytecode.appendSlice(self.allocator, &uv_bytes) catch return error.OutOfMemory;
        // Each upvalue: [is_local: u8][index: u16]
        for (upvalue_list) |uv| {
            self.bytecode.append(self.allocator, if (uv.is_local) @as(u8, 1) else @as(u8, 0)) catch return error.OutOfMemory;
            const idx_bytes = std.mem.toBytes(std.mem.nativeToLittle(u16, uv.index));
            self.bytecode.appendSlice(self.allocator, &idx_bytes) catch return error.OutOfMemory;
        }
    }

    // ---- Debug info ----

    fn addDebugLine(self: *Compiler, line: u32) void {
        const offset: u32 = @intCast(self.bytecode.items.len);
        // Avoid duplicate entries for the same offset
        if (self.debug_lines.items.len > 0) {
            const last = self.debug_lines.items[self.debug_lines.items.len - 1];
            if (last.bytecode_offset == offset) return;
        }
        self.debug_lines.append(self.allocator, .{
            .bytecode_offset = offset,
            .source_line = line,
        }) catch {};
    }
};

// ---- Test helpers ----

const TestContext = struct {
    module: CompiledModule,
    compiler: Compiler,
    diags: diagnostic.DiagnosticList,
    nodes: ast.NodeStore,
    arena: std.heap.ArenaAllocator,
    root: NodeIndex,

    fn deinit(self: *TestContext) void {
        // Arena handles all memory; individual deinit calls would double-free
        self.arena.deinit();
    }
};

fn compileSource(source: []const u8) !TestContext {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    var diags = diagnostic.DiagnosticList.init(allocator);
    var nodes = ast.NodeStore.init(allocator);

    var lexer = @import("lexer.zig").Lexer.init(source, &diags, .logic);
    var parser = @import("parser.zig").Parser.init(allocator, &lexer, &nodes, &diags);
    const root = try parser.parseProgram();

    var compiler = Compiler.init(allocator, &nodes, &diags);
    const module = try compiler.compile(root);

    return .{
        .module = module,
        .compiler = compiler,
        .diags = diags,
        .nodes = nodes,
        .arena = arena,
        .root = root,
    };
}

// ---- Tests ----

test "compile integer literal" {
    var ctx = try compileSource("let x = 42\n");
    defer ctx.deinit();

    try std.testing.expect(!ctx.diags.hasErrors());
    try std.testing.expect(ctx.module.bytecode.len > 0);

    var found = false;
    for (ctx.module.constants) |c| {
        if (c == .int and c.int == 42) found = true;
    }
    try std.testing.expect(found);
}

test "compile arithmetic" {
    var ctx = try compileSource("let x = 1 + 2\n");
    defer ctx.deinit();

    try std.testing.expect(!ctx.diags.hasErrors());

    var found_add = false;
    for (ctx.module.bytecode) |b| {
        if (b == @intFromEnum(OpCode.add)) found_add = true;
    }
    try std.testing.expect(found_add);
}

test "compile if/else" {
    var ctx = try compileSource(
        \\let x = 10
        \\if x > 5 {
        \\  let a = 1
        \\} else {
        \\  let b = 2
        \\}
        \\
    );
    defer ctx.deinit();

    try std.testing.expect(!ctx.diags.hasErrors());

    var found_jif = false;
    for (ctx.module.bytecode) |b| {
        if (b == @intFromEnum(OpCode.jump_if_not)) found_jif = true;
    }
    try std.testing.expect(found_jif);
}

test "compile while loop" {
    var ctx = try compileSource(
        \\let x = 0
        \\while x < 10 {
        \\  x = x + 1
        \\}
        \\
    );
    defer ctx.deinit();

    try std.testing.expect(!ctx.diags.hasErrors());

    var has_jump = false;
    for (ctx.module.bytecode) |b| {
        if (b == @intFromEnum(OpCode.jump)) has_jump = true;
    }
    try std.testing.expect(has_jump);
}

test "compile function" {
    var ctx = try compileSource(
        \\fn add(a, b) {
        \\  return a + b
        \\}
        \\
    );
    defer ctx.deinit();

    try std.testing.expect(!ctx.diags.hasErrors());
    try std.testing.expect(ctx.module.functions.len >= 2);
}

test "compile for range" {
    var ctx = try compileSource(
        \\let sum = 0
        \\for i in 0..5 {
        \\  sum = sum + i
        \\}
        \\
    );
    defer ctx.deinit();

    try std.testing.expect(!ctx.diags.hasErrors());
}

test "serialize and deserialize .neruc" {
    var ctx = try compileSource("let x = 42\n");
    defer ctx.deinit();

    const allocator = ctx.arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try ctx.module.serialize(buf.writer(allocator).any());

    const loaded = try CompiledModule.deserialize(buf.items, allocator);

    try std.testing.expectEqual(ctx.module.constants.len, loaded.constants.len);
    try std.testing.expectEqual(ctx.module.functions.len, loaded.functions.len);
    try std.testing.expectEqualSlices(u8, ctx.module.bytecode, loaded.bytecode);
}

test "debug lines are generated" {
    var ctx = try compileSource("let x = 1\nlet y = 2\n");
    defer ctx.deinit();

    try std.testing.expect(ctx.module.debug_lines.len > 0);
}
