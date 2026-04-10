const std = @import("std");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");
const diagnostic = @import("diagnostic.zig");
const token_mod = @import("token.zig");

const Tag = token_mod.Tag;
const Token = token_mod.Token;
const Span = token_mod.Span;
const NodeIndex = ast.NodeIndex;

pub const ParseError = error{
    UnexpectedToken,
    OutOfMemory,
};

pub const Parser = struct {
    lexer: *lexer_mod.Lexer,
    current: Token,
    previous: Token,
    nodes: *ast.NodeStore,
    diagnostics: *diagnostic.DiagnosticList,
    allocator: std.mem.Allocator,
    had_error: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        lexer: *lexer_mod.Lexer,
        nodes: *ast.NodeStore,
        diagnostics: *diagnostic.DiagnosticList,
    ) Parser {
        var p = Parser{
            .allocator = allocator,
            .lexer = lexer,
            .nodes = nodes,
            .diagnostics = diagnostics,
            .current = undefined,
            .previous = undefined,
            .had_error = false,
        };
        p.advance();
        return p;
    }

    pub fn parseProgram(self: *Parser) ParseError!NodeIndex {
        var stmts: std.ArrayList(NodeIndex) = .empty;
        defer stmts.deinit(self.allocator);

        self.skipNewlines();

        while (self.current.tag != .eof) {
            const stmt = self.parseStatement() catch |err| {
                if (err == error.OutOfMemory) return err;
                self.synchronize();
                continue;
            };
            stmts.append(self.allocator, stmt) catch return error.OutOfMemory;
            self.skipNewlines();
        }

        const owned_stmts = self.allocator.dupe(NodeIndex, stmts.items) catch return error.OutOfMemory;
        const span = if (owned_stmts.len > 0)
            Span{
                .start = self.nodes.getNode(owned_stmts[0]).span().start,
                .end = self.nodes.getNode(owned_stmts[owned_stmts.len - 1]).span().end,
            }
        else
            Span{
                .start = .{ .line = 1, .column = 1, .offset = 0 },
                .end = self.current.span.end,
            };

        return self.nodes.addNode(.{ .program = .{
            .stmts = owned_stmts,
            .span = span,
        } }) catch return error.OutOfMemory;
    }

    // ---- Statement parsers ----

    fn parseStatement(self: *Parser) ParseError!NodeIndex {
        return switch (self.current.tag) {
            .kw_let => self.parseLetStmt(),
            .kw_fn => self.parseFnDecl(),
            .kw_if => self.parseIfStmt(),
            .kw_for => self.parseForStmt(),
            .kw_while => self.parseWhileStmt(),
            .kw_return => self.parseReturnStmt(),
            .kw_break => self.parseBreakStmt(),
            .kw_continue => self.parseContinueStmt(),
            else => self.parseAssignOrExprStmt(),
        };
    }

    fn parseLetStmt(self: *Parser) ParseError!NodeIndex {
        const start = self.current.span.start;
        self.advance(); // skip 'let'

        const name = try self.expectIdent();
        try self.expect(.assign);
        const value = try self.parseExpression();
        try self.expectNewlineOrEof();

        return self.addNode(.{ .let_stmt = .{
            .name = name,
            .value = value,
            .span = self.spanFrom(start),
        } });
    }

    fn parseFnDecl(self: *Parser) ParseError!NodeIndex {
        const start = self.current.span.start;
        self.advance(); // skip 'fn'

        const name = try self.expectIdent();
        try self.expect(.lparen);

        var params: std.ArrayList([]const u8) = .empty;
        defer params.deinit(self.allocator);

        if (self.current.tag != .rparen) {
            const first = try self.expectIdent();
            params.append(self.allocator, first) catch return error.OutOfMemory;
            while (self.matchTag(.comma)) {
                const param = try self.expectIdent();
                params.append(self.allocator, param) catch return error.OutOfMemory;
            }
        }
        try self.expect(.rparen);

        const body = try self.parseBlock();

        const owned_params = self.allocator.dupe([]const u8, params.items) catch return error.OutOfMemory;

        return self.addNode(.{ .fn_decl = .{
            .name = name,
            .params = owned_params,
            .body = body,
            .span = self.spanFrom(start),
        } });
    }

    fn parseIfStmt(self: *Parser) ParseError!NodeIndex {
        const start = self.current.span.start;
        self.advance(); // skip 'if'

        const condition = try self.parseExpression();
        const then_body = try self.parseBlock();

        var else_ifs: std.ArrayList(ast.ElseIfClause) = .empty;
        defer else_ifs.deinit(self.allocator);
        var else_body: ?[]const NodeIndex = null;

        self.skipNewlines();

        while (self.current.tag == .kw_else) {
            self.advance(); // skip 'else'

            if (self.current.tag == .kw_if) {
                self.advance(); // skip 'if'
                const elif_cond = try self.parseExpression();
                const elif_body = try self.parseBlock();
                else_ifs.append(self.allocator, .{
                    .condition = elif_cond,
                    .body = elif_body,
                }) catch return error.OutOfMemory;
                self.skipNewlines();
            } else {
                else_body = try self.parseBlock();
                break;
            }
        }

        const owned_else_ifs = self.allocator.dupe(ast.ElseIfClause, else_ifs.items) catch return error.OutOfMemory;

        return self.addNode(.{ .if_stmt = .{
            .condition = condition,
            .then_body = then_body,
            .else_if_clauses = owned_else_ifs,
            .else_body = else_body,
            .span = self.spanFrom(start),
        } });
    }

    fn parseForStmt(self: *Parser) ParseError!NodeIndex {
        const start = self.current.span.start;
        self.advance(); // skip 'for'

        const iter_name = try self.expectIdent();
        try self.expect(.kw_in);
        const iterable = try self.parseExpression();
        const body = try self.parseBlock();

        return self.addNode(.{ .for_stmt = .{
            .iterator_name = iter_name,
            .iterable = iterable,
            .body = body,
            .span = self.spanFrom(start),
        } });
    }

    fn parseWhileStmt(self: *Parser) ParseError!NodeIndex {
        const start = self.current.span.start;
        self.advance(); // skip 'while'

        const condition = try self.parseExpression();
        const body = try self.parseBlock();

        return self.addNode(.{ .while_stmt = .{
            .condition = condition,
            .body = body,
            .span = self.spanFrom(start),
        } });
    }

    fn parseReturnStmt(self: *Parser) ParseError!NodeIndex {
        const start = self.current.span.start;
        self.advance(); // skip 'return'

        var value: ?NodeIndex = null;
        if (self.current.tag != .newline and self.current.tag != .eof and self.current.tag != .rbrace) {
            value = try self.parseExpression();
        }
        try self.expectNewlineOrEof();

        return self.addNode(.{ .return_stmt = .{
            .value = value,
            .span = self.spanFrom(start),
        } });
    }

    fn parseBreakStmt(self: *Parser) ParseError!NodeIndex {
        const start = self.current.span.start;
        self.advance(); // skip 'break'
        try self.expectNewlineOrEof();
        return self.addNode(.{ .break_stmt = .{ .span = self.spanFrom(start) } });
    }

    fn parseContinueStmt(self: *Parser) ParseError!NodeIndex {
        const start = self.current.span.start;
        self.advance(); // skip 'continue'
        try self.expectNewlineOrEof();
        return self.addNode(.{ .continue_stmt = .{ .span = self.spanFrom(start) } });
    }

    fn parseAssignOrExprStmt(self: *Parser) ParseError!NodeIndex {
        const start = self.current.span.start;
        const expr = try self.parseExpression();

        // Check if followed by assignment operator
        if (self.toAssignOp(self.current.tag)) |op| {
            self.advance(); // skip assignment operator
            const value = try self.parseExpression();
            try self.expectNewlineOrEof();
            return self.addNode(.{ .assign_stmt = .{
                .target = expr,
                .op = op,
                .value = value,
                .span = self.spanFrom(start),
            } });
        }

        try self.expectNewlineOrEof();
        return self.addNode(.{ .expr_stmt = .{
            .expr = expr,
            .span = self.spanFrom(start),
        } });
    }

    fn parseBlock(self: *Parser) ParseError![]const NodeIndex {
        self.skipNewlines();
        try self.expect(.lbrace);
        self.skipNewlines();

        var stmts: std.ArrayList(NodeIndex) = .empty;
        defer stmts.deinit(self.allocator);

        while (self.current.tag != .rbrace and self.current.tag != .eof) {
            const stmt = self.parseStatement() catch |err| {
                if (err == error.OutOfMemory) return err;
                self.synchronize();
                continue;
            };
            stmts.append(self.allocator, stmt) catch return error.OutOfMemory;
            self.skipNewlines();
        }

        try self.expect(.rbrace);

        return self.allocator.dupe(NodeIndex, stmts.items) catch return error.OutOfMemory;
    }

    // ---- Expression parser (precedence climbing) ----

    const Precedence = enum(u8) {
        none = 0,
        or_prec = 1,
        and_prec = 2,
        equality = 3,
        comparison = 4,
        range = 5,
        additive = 6,
        multiplicative = 7,
        unary = 8,
        postfix = 9,
    };

    fn parseExpression(self: *Parser) ParseError!NodeIndex {
        return self.parsePrecedence(.or_prec);
    }

    fn parsePrecedence(self: *Parser, min_prec: Precedence) ParseError!NodeIndex {
        var left = try self.parseUnary();

        while (true) {
            // Postfix operations
            if (self.current.tag == .lparen or self.current.tag == .lbracket or self.current.tag == .dot) {
                if (@intFromEnum(Precedence.postfix) >= @intFromEnum(min_prec)) {
                    left = try self.parsePostfix(left);
                    continue;
                }
            }

            // Range operator
            if (self.current.tag == .dot_dot) {
                if (@intFromEnum(Precedence.range) >= @intFromEnum(min_prec)) {
                    left = try self.parseRange(left);
                    continue;
                }
            }

            // Binary operators
            const op_info = self.getBinaryOpInfo(self.current.tag) orelse break;
            if (@intFromEnum(op_info.prec) < @intFromEnum(min_prec)) break;

            self.advance(); // skip operator
            const next_prec: Precedence = @enumFromInt(@intFromEnum(op_info.prec) + 1);
            const right = try self.parsePrecedence(next_prec);

            const span = Span{
                .start = self.nodes.getNode(left).span().start,
                .end = self.nodes.getNode(right).span().end,
            };
            left = try self.addNode(.{ .binary_expr = .{
                .left = left,
                .op = op_info.op,
                .right = right,
                .span = span,
            } });
        }

        return left;
    }

    fn parseUnary(self: *Parser) ParseError!NodeIndex {
        if (self.current.tag == .not) {
            const start = self.current.span.start;
            self.advance();
            const operand = try self.parseUnary();
            return self.addNode(.{ .unary_expr = .{
                .op = .not,
                .operand = operand,
                .span = self.spanFrom(start),
            } });
        }
        if (self.current.tag == .minus) {
            const start = self.current.span.start;
            self.advance();
            const operand = try self.parseUnary();
            return self.addNode(.{ .unary_expr = .{
                .op = .negate,
                .operand = operand,
                .span = self.spanFrom(start),
            } });
        }
        return self.parsePrimary();
    }

    fn parsePostfix(self: *Parser, left: NodeIndex) ParseError!NodeIndex {
        const left_span = self.nodes.getNode(left).span();

        switch (self.current.tag) {
            .lparen => {
                self.advance(); // skip '('
                var args: std.ArrayList(NodeIndex) = .empty;
                defer args.deinit(self.allocator);

                if (self.current.tag != .rparen) {
                    const first = try self.parseExpression();
                    args.append(self.allocator, first) catch return error.OutOfMemory;
                    while (self.matchTag(.comma)) {
                        const arg = try self.parseExpression();
                        args.append(self.allocator, arg) catch return error.OutOfMemory;
                    }
                }
                try self.expect(.rparen);
                const owned_args = self.allocator.dupe(NodeIndex, args.items) catch return error.OutOfMemory;

                return self.addNode(.{ .call_expr = .{
                    .callee = left,
                    .args = owned_args,
                    .span = .{ .start = left_span.start, .end = self.previous.span.end },
                } });
            },
            .lbracket => {
                self.advance(); // skip '['
                const index = try self.parseExpression();
                try self.expect(.rbracket);

                return self.addNode(.{ .index_expr = .{
                    .object = left,
                    .index = index,
                    .span = .{ .start = left_span.start, .end = self.previous.span.end },
                } });
            },
            .dot => {
                self.advance(); // skip '.'
                const member = try self.expectIdent();

                return self.addNode(.{ .member_expr = .{
                    .object = left,
                    .member = member,
                    .span = .{ .start = left_span.start, .end = self.previous.span.end },
                } });
            },
            else => return left,
        }
    }

    fn parseRange(self: *Parser, left: NodeIndex) ParseError!NodeIndex {
        self.advance(); // skip '..'
        const right = try self.parsePrecedence(@enumFromInt(@intFromEnum(Precedence.range) + 1));

        return self.addNode(.{ .range_expr = .{
            .start = left,
            .end = right,
            .span = .{
                .start = self.nodes.getNode(left).span().start,
                .end = self.nodes.getNode(right).span().end,
            },
        } });
    }

    fn parsePrimary(self: *Parser) ParseError!NodeIndex {
        switch (self.current.tag) {
            .int_literal => return self.parseIntLiteral(),
            .float_literal => return self.parseFloatLiteral(),
            .string_literal => return self.parseStringLiteral(),
            .kw_true => return self.parseBoolLiteral(true),
            .kw_false => return self.parseBoolLiteral(false),
            .kw_null => return self.parseNullLiteral(),
            .identifier, .kw_state => return self.parseIdentifier(),
            .lparen => return self.parseGrouped(),
            .lbracket => return self.parseArrayLiteral(),
            .lbrace => return self.parseMapLiteral(),
            else => {
                self.reportError("expected expression");
                return error.UnexpectedToken;
            },
        }
    }

    fn parseIntLiteral(self: *Parser) ParseError!NodeIndex {
        const tok = self.current;
        self.advance();

        const value = parseIntValue(tok.lexeme) catch {
            self.diagnostics.addError(.parser, tok.span, "invalid integer literal");
            return self.addNode(.{ .literal_expr = .{
                .value = .{ .int = 0 },
                .span = tok.span,
            } });
        };

        return self.addNode(.{ .literal_expr = .{
            .value = .{ .int = value },
            .span = tok.span,
        } });
    }

    fn parseFloatLiteral(self: *Parser) ParseError!NodeIndex {
        const tok = self.current;
        self.advance();

        const value = std.fmt.parseFloat(f64, tok.lexeme) catch {
            self.diagnostics.addError(.parser, tok.span, "invalid float literal");
            return self.addNode(.{ .literal_expr = .{
                .value = .{ .float = 0.0 },
                .span = tok.span,
            } });
        };

        return self.addNode(.{ .literal_expr = .{
            .value = .{ .float = value },
            .span = tok.span,
        } });
    }

    fn parseStringLiteral(self: *Parser) ParseError!NodeIndex {
        const tok = self.current;
        self.advance();
        // Strip quotes from lexeme
        const raw = tok.lexeme;
        const content = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;

        return self.addNode(.{ .literal_expr = .{
            .value = .{ .string = content },
            .span = tok.span,
        } });
    }

    fn parseBoolLiteral(self: *Parser, value: bool) ParseError!NodeIndex {
        const tok = self.current;
        self.advance();
        return self.addNode(.{ .literal_expr = .{
            .value = .{ .bool_val = value },
            .span = tok.span,
        } });
    }

    fn parseNullLiteral(self: *Parser) ParseError!NodeIndex {
        const tok = self.current;
        self.advance();
        return self.addNode(.{ .literal_expr = .{
            .value = .{ .null_val = {} },
            .span = tok.span,
        } });
    }

    fn parseIdentifier(self: *Parser) ParseError!NodeIndex {
        const tok = self.current;
        self.advance();
        return self.addNode(.{ .identifier_expr = .{
            .name = tok.lexeme,
            .span = tok.span,
        } });
    }

    fn parseGrouped(self: *Parser) ParseError!NodeIndex {
        const start = self.current.span.start;
        self.advance(); // skip '('
        const inner = try self.parseExpression();
        try self.expect(.rparen);
        return self.addNode(.{ .grouped_expr = .{
            .inner = inner,
            .span = self.spanFrom(start),
        } });
    }

    fn parseArrayLiteral(self: *Parser) ParseError!NodeIndex {
        const start = self.current.span.start;
        self.advance(); // skip '['
        self.skipNewlines();

        var elements: std.ArrayList(NodeIndex) = .empty;
        defer elements.deinit(self.allocator);

        if (self.current.tag != .rbracket) {
            const first = try self.parseExpression();
            elements.append(self.allocator, first) catch return error.OutOfMemory;
            while (self.matchTag(.comma)) {
                self.skipNewlines();
                if (self.current.tag == .rbracket) break; // trailing comma
                const elem = try self.parseExpression();
                elements.append(self.allocator, elem) catch return error.OutOfMemory;
            }
        }

        self.skipNewlines();
        try self.expect(.rbracket);
        const owned = self.allocator.dupe(NodeIndex, elements.items) catch return error.OutOfMemory;

        return self.addNode(.{ .array_expr = .{
            .elements = owned,
            .span = self.spanFrom(start),
        } });
    }

    fn parseMapLiteral(self: *Parser) ParseError!NodeIndex {
        const start = self.current.span.start;
        self.advance(); // skip '{'
        self.skipNewlines();

        var entries: std.ArrayList(ast.MapEntry) = .empty;
        defer entries.deinit(self.allocator);

        if (self.current.tag != .rbrace) {
            const entry = try self.parseMapEntry();
            entries.append(self.allocator, entry) catch return error.OutOfMemory;
            while (self.matchTag(.comma)) {
                self.skipNewlines();
                if (self.current.tag == .rbrace) break; // trailing comma
                const e = try self.parseMapEntry();
                entries.append(self.allocator, e) catch return error.OutOfMemory;
            }
        }

        self.skipNewlines();
        try self.expect(.rbrace);
        const owned = self.allocator.dupe(ast.MapEntry, entries.items) catch return error.OutOfMemory;

        return self.addNode(.{ .map_expr = .{
            .entries = owned,
            .span = self.spanFrom(start),
        } });
    }

    fn parseMapEntry(self: *Parser) ParseError!ast.MapEntry {
        self.skipNewlines();
        const key = try self.parsePrimary();
        try self.expect(.colon);
        const value = try self.parseExpression();
        return .{ .key = key, .value = value };
    }

    // ---- Utilities ----

    fn advance(self: *Parser) void {
        self.previous = self.current;
        self.current = self.lexer.next();
    }

    fn expect(self: *Parser, tag: Tag) ParseError!void {
        if (self.current.tag == tag) {
            self.advance();
            return;
        }
        self.reportErrorFmt("expected '{s}', got '{s}'", .{ tag.symbol(), self.current.tag.symbol() });
        return error.UnexpectedToken;
    }

    fn expectIdent(self: *Parser) ParseError![]const u8 {
        if (self.current.tag == .identifier) {
            const name = self.current.lexeme;
            self.advance();
            return name;
        }
        self.reportError("expected identifier");
        return error.UnexpectedToken;
    }

    fn expectNewlineOrEof(self: *Parser) ParseError!void {
        if (self.current.tag == .newline) {
            self.advance();
            return;
        }
        if (self.current.tag == .eof) return;
        if (self.current.tag == .rbrace) return; // allow statement before '}'
        self.reportError("expected newline or end of file");
        return error.UnexpectedToken;
    }

    fn matchTag(self: *Parser, tag: Tag) bool {
        if (self.current.tag == tag) {
            self.advance();
            return true;
        }
        return false;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.current.tag == .newline) {
            self.advance();
        }
    }

    fn synchronize(self: *Parser) void {
        self.had_error = true;
        while (self.current.tag != .eof) {
            if (self.previous.tag == .newline) return;
            switch (self.current.tag) {
                .kw_let, .kw_fn, .kw_if, .kw_for, .kw_while, .kw_return, .kw_break, .kw_continue => return,
                else => self.advance(),
            }
        }
    }

    fn addNode(self: *Parser, node: ast.Node) ParseError!NodeIndex {
        return self.nodes.addNode(node) catch return error.OutOfMemory;
    }

    fn spanFrom(self: *const Parser, start: token_mod.SourceLocation) Span {
        return .{ .start = start, .end = self.previous.span.end };
    }

    fn reportError(self: *Parser, message: []const u8) void {
        self.had_error = true;
        self.diagnostics.addError(.parser, self.current.span, message);
    }

    fn reportErrorFmt(self: *Parser, comptime fmt: []const u8, args: anytype) void {
        self.had_error = true;
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch "error";
        self.diagnostics.addError(.parser, self.current.span, message);
    }

    const BinaryOpInfo = struct {
        op: ast.BinaryOp,
        prec: Precedence,
    };

    fn getBinaryOpInfo(self: *const Parser, tag: Tag) ?BinaryOpInfo {
        _ = self;
        return switch (tag) {
            .@"or" => .{ .op = .@"or", .prec = .or_prec },
            .@"and" => .{ .op = .@"and", .prec = .and_prec },
            .eq => .{ .op = .eq, .prec = .equality },
            .neq => .{ .op = .neq, .prec = .equality },
            .lt => .{ .op = .lt, .prec = .comparison },
            .gt => .{ .op = .gt, .prec = .comparison },
            .lte => .{ .op = .lte, .prec = .comparison },
            .gte => .{ .op = .gte, .prec = .comparison },
            .plus => .{ .op = .add, .prec = .additive },
            .minus => .{ .op = .sub, .prec = .additive },
            .star => .{ .op = .mul, .prec = .multiplicative },
            .slash => .{ .op = .div, .prec = .multiplicative },
            .percent => .{ .op = .mod, .prec = .multiplicative },
            else => null,
        };
    }

    fn toAssignOp(self: *const Parser, tag: Tag) ?ast.AssignOp {
        _ = self;
        return switch (tag) {
            .assign => .assign,
            .plus_assign => .plus_assign,
            .minus_assign => .minus_assign,
            .star_assign => .star_assign,
            .slash_assign => .slash_assign,
            .percent_assign => .percent_assign,
            else => null,
        };
    }
};

fn parseIntValue(lexeme: []const u8) !i64 {
    if (lexeme.len > 2 and lexeme[0] == '0') {
        if (lexeme[1] == 'x' or lexeme[1] == 'X') {
            return std.fmt.parseInt(i64, lexeme[2..], 16);
        }
        if (lexeme[1] == 'b' or lexeme[1] == 'B') {
            return std.fmt.parseInt(i64, lexeme[2..], 2);
        }
    }
    return std.fmt.parseInt(i64, lexeme, 10);
}

// ---- Test helpers ----

fn parseSource(source: []const u8, allocator: std.mem.Allocator) !struct {
    nodes: ast.NodeStore,
    diags: diagnostic.DiagnosticList,
    root: NodeIndex,
} {
    var diags = diagnostic.DiagnosticList.init(allocator);
    var nodes = ast.NodeStore.init(allocator);
    var lexer = lexer_mod.Lexer.init(source, &diags);
    var parser = Parser.init(allocator, &lexer, &nodes, &diags);

    const root = try parser.parseProgram();
    return .{ .nodes = nodes, .diags = diags, .root = root };
}

fn getStmt(result: anytype, index: usize) ast.Node {
    const program = result.nodes.getNode(result.root).program;
    return result.nodes.getNode(program.stmts[index]);
}

// ---- Tests ----

test "parse empty program" {
    const allocator = std.testing.allocator;
    var result = try parseSource("", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();

    const node = result.nodes.getNode(result.root);
    try std.testing.expectEqual(@as(usize, 0), node.program.stmts.len);
}

test "parse let statement" {
    const allocator = std.testing.allocator;
    var result = try parseSource("let x = 42\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    try std.testing.expectEqualStrings("x", stmt.let_stmt.name);

    const val = result.nodes.getNode(stmt.let_stmt.value);
    try std.testing.expectEqual(@as(i64, 42), val.literal_expr.value.int);
}

test "parse arithmetic precedence" {
    const allocator = std.testing.allocator;
    // 1 + 2 * 3 should parse as 1 + (2 * 3)
    var result = try parseSource("let x = 1 + 2 * 3\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const expr = result.nodes.getNode(stmt.let_stmt.value);
    try std.testing.expectEqual(ast.BinaryOp.add, expr.binary_expr.op);

    const right = result.nodes.getNode(expr.binary_expr.right);
    try std.testing.expectEqual(ast.BinaryOp.mul, right.binary_expr.op);
}

test "parse unary negation" {
    const allocator = std.testing.allocator;
    var result = try parseSource("let x = -42\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const expr = result.nodes.getNode(stmt.let_stmt.value);
    try std.testing.expectEqual(ast.UnaryOp.negate, expr.unary_expr.op);
}

test "parse function declaration" {
    const allocator = std.testing.allocator;
    var result = try parseSource("fn add(a, b) {\n  return a + b\n}\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer {
        const program = result.nodes.getNode(result.root).program;
        allocator.free(program.stmts);
    }

    const stmt = getStmt(&result, 0);
    try std.testing.expectEqualStrings("add", stmt.fn_decl.name);
    try std.testing.expectEqual(@as(usize, 2), stmt.fn_decl.params.len);
    try std.testing.expectEqualStrings("a", stmt.fn_decl.params[0]);
    try std.testing.expectEqualStrings("b", stmt.fn_decl.params[1]);

    // Free owned slices
    allocator.free(stmt.fn_decl.params);
    allocator.free(stmt.fn_decl.body);
}

test "parse if/else if/else" {
    const allocator = std.testing.allocator;
    var result = try parseSource(
        \\if x > 0 {
        \\  let a = 1
        \\} else if x < 0 {
        \\  let b = 2
        \\} else {
        \\  let c = 3
        \\}
        \\
    , allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer {
        const program = result.nodes.getNode(result.root).program;
        allocator.free(program.stmts);
    }

    const stmt = getStmt(&result, 0);
    try std.testing.expectEqual(@as(usize, 1), stmt.if_stmt.else_if_clauses.len);
    try std.testing.expect(stmt.if_stmt.else_body != null);

    // Free owned slices
    allocator.free(stmt.if_stmt.then_body);
    allocator.free(stmt.if_stmt.else_if_clauses[0].body);
    allocator.free(stmt.if_stmt.else_if_clauses);
    allocator.free(stmt.if_stmt.else_body.?);
}

test "parse for range" {
    const allocator = std.testing.allocator;
    var result = try parseSource("for i in 0..10 {\n}\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer {
        const program = result.nodes.getNode(result.root).program;
        allocator.free(program.stmts);
    }

    const stmt = getStmt(&result, 0);
    try std.testing.expectEqualStrings("i", stmt.for_stmt.iterator_name);

    const iterable = result.nodes.getNode(stmt.for_stmt.iterable);
    try std.testing.expect(iterable == .range_expr);

    allocator.free(stmt.for_stmt.body);
}

test "parse while" {
    const allocator = std.testing.allocator;
    var result = try parseSource("while x > 0 {\n  x = x - 1\n}\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer {
        const program = result.nodes.getNode(result.root).program;
        allocator.free(program.stmts);
    }

    const stmt = getStmt(&result, 0);
    try std.testing.expectEqual(@as(usize, 1), stmt.while_stmt.body.len);
    allocator.free(stmt.while_stmt.body);
}

test "parse function call" {
    const allocator = std.testing.allocator;
    var result = try parseSource("foo(1, 2, 3)\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const call = result.nodes.getNode(stmt.expr_stmt.expr);
    try std.testing.expectEqual(@as(usize, 3), call.call_expr.args.len);
    allocator.free(call.call_expr.args);
}

test "parse member access" {
    const allocator = std.testing.allocator;
    var result = try parseSource("obj.field\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const expr = result.nodes.getNode(stmt.expr_stmt.expr);
    try std.testing.expectEqualStrings("field", expr.member_expr.member);
}

test "parse index access" {
    const allocator = std.testing.allocator;
    var result = try parseSource("arr[0]\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const expr = result.nodes.getNode(stmt.expr_stmt.expr);
    try std.testing.expect(expr == .index_expr);
}

test "parse chained postfix" {
    const allocator = std.testing.allocator;
    var result = try parseSource("obj.method(arg)[0]\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const expr = result.nodes.getNode(stmt.expr_stmt.expr);
    // outermost is index_expr
    try std.testing.expect(expr == .index_expr);
    // inner is call_expr
    const inner = result.nodes.getNode(expr.index_expr.object);
    try std.testing.expect(inner == .call_expr);
    allocator.free(inner.call_expr.args);
}

test "parse array literal" {
    const allocator = std.testing.allocator;
    var result = try parseSource("let x = [1, 2, 3]\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const arr = result.nodes.getNode(stmt.let_stmt.value);
    try std.testing.expectEqual(@as(usize, 3), arr.array_expr.elements.len);
    allocator.free(arr.array_expr.elements);
}

test "parse map literal" {
    const allocator = std.testing.allocator;
    var result = try parseSource("let m = {\"a\": 1, \"b\": 2}\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const map = result.nodes.getNode(stmt.let_stmt.value);
    try std.testing.expectEqual(@as(usize, 2), map.map_expr.entries.len);
    allocator.free(map.map_expr.entries);
}

test "parse assignment operators" {
    const allocator = std.testing.allocator;
    var result = try parseSource("x += 1\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    try std.testing.expectEqual(ast.AssignOp.plus_assign, stmt.assign_stmt.op);
}

test "parse state access" {
    const allocator = std.testing.allocator;
    var result = try parseSource("state.hp = 100\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    try std.testing.expect(stmt == .assign_stmt);
    const target = result.nodes.getNode(stmt.assign_stmt.target);
    try std.testing.expect(target == .member_expr);
    try std.testing.expectEqualStrings("hp", target.member_expr.member);
}

test "parse logical operators" {
    const allocator = std.testing.allocator;
    // a && b || c should parse as (a && b) || c
    var result = try parseSource("let x = a && b || c\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const expr = result.nodes.getNode(stmt.let_stmt.value);
    try std.testing.expectEqual(ast.BinaryOp.@"or", expr.binary_expr.op);

    const left = result.nodes.getNode(expr.binary_expr.left);
    try std.testing.expectEqual(ast.BinaryOp.@"and", left.binary_expr.op);
}

test "parse comparison" {
    const allocator = std.testing.allocator;
    var result = try parseSource("let x = a == b\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const expr = result.nodes.getNode(stmt.let_stmt.value);
    try std.testing.expectEqual(ast.BinaryOp.eq, expr.binary_expr.op);
}

test "parse grouped expression" {
    const allocator = std.testing.allocator;
    // (1 + 2) * 3 should parse as (grouped) * 3
    var result = try parseSource("let x = (1 + 2) * 3\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const expr = result.nodes.getNode(stmt.let_stmt.value);
    try std.testing.expectEqual(ast.BinaryOp.mul, expr.binary_expr.op);

    const left = result.nodes.getNode(expr.binary_expr.left);
    try std.testing.expect(left == .grouped_expr);
}

test "parse multiple statements" {
    const allocator = std.testing.allocator;
    var result = try parseSource("let x = 1\nlet y = 2\nlet z = x + y\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const program = result.nodes.getNode(result.root).program;
    try std.testing.expectEqual(@as(usize, 3), program.stmts.len);
}

test "parse break and continue" {
    const allocator = std.testing.allocator;
    var result = try parseSource("while true {\n  break\n  continue\n}\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer {
        const program = result.nodes.getNode(result.root).program;
        allocator.free(program.stmts);
    }

    const stmt = getStmt(&result, 0);
    try std.testing.expectEqual(@as(usize, 2), stmt.while_stmt.body.len);

    const brk = result.nodes.getNode(stmt.while_stmt.body[0]);
    try std.testing.expect(brk == .break_stmt);

    const cont = result.nodes.getNode(stmt.while_stmt.body[1]);
    try std.testing.expect(cont == .continue_stmt);

    allocator.free(stmt.while_stmt.body);
}

test "parse return with value" {
    const allocator = std.testing.allocator;
    var result = try parseSource("fn f() {\n  return 42\n}\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer {
        const program = result.nodes.getNode(result.root).program;
        allocator.free(program.stmts);
    }

    const fn_decl = getStmt(&result, 0).fn_decl;
    const ret = result.nodes.getNode(fn_decl.body[0]);
    try std.testing.expect(ret.return_stmt.value != null);

    allocator.free(fn_decl.params);
    allocator.free(fn_decl.body);
}

test "parse return without value" {
    const allocator = std.testing.allocator;
    var result = try parseSource("fn f() {\n  return\n}\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer {
        const program = result.nodes.getNode(result.root).program;
        allocator.free(program.stmts);
    }

    const fn_decl = getStmt(&result, 0).fn_decl;
    const ret = result.nodes.getNode(fn_decl.body[0]);
    try std.testing.expect(ret.return_stmt.value == null);

    allocator.free(fn_decl.params);
    allocator.free(fn_decl.body);
}

test "parse string literal content" {
    const allocator = std.testing.allocator;
    var result = try parseSource("let s = \"hello\"\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const val = result.nodes.getNode(stmt.let_stmt.value);
    try std.testing.expectEqualStrings("hello", val.literal_expr.value.string);
}

test "parse empty map" {
    const allocator = std.testing.allocator;
    var result = try parseSource("let m = {}\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    const stmt = getStmt(&result, 0);
    const map = result.nodes.getNode(stmt.let_stmt.value);
    try std.testing.expectEqual(@as(usize, 0), map.map_expr.entries.len);
    allocator.free(map.map_expr.entries);
}

test "error recovery continues parsing" {
    const allocator = std.testing.allocator;
    var result = try parseSource("let = 1\nlet y = 2\n", allocator);
    defer result.nodes.deinit();
    defer result.diags.deinit();
    defer allocator.free(result.nodes.getNode(result.root).program.stmts);

    // Should have reported an error but still parsed second statement
    try std.testing.expect(result.diags.hasErrors());
    const program = result.nodes.getNode(result.root).program;
    try std.testing.expect(program.stmts.len >= 1);
}
