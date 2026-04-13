const std = @import("std");
const token = @import("token.zig");
const diagnostic = @import("diagnostic.zig");

pub const Token = token.Token;
pub const Tag = token.Tag;
pub const SourceLocation = token.SourceLocation;
pub const Span = token.Span;

pub const Mode = enum {
    logic,
    scenario,

    pub fn fromPath(path: []const u8) Mode {
        return if (std.mem.endsWith(u8, path, ".neru")) .scenario else .logic;
    }
};

pub const Lexer = struct {
    source: []const u8,
    pos: u32,
    line: u32,
    column: u32,
    diagnostics: *diagnostic.DiagnosticList,
    prev_was_newline: bool,
    mode: Mode,
    /// True when the lexer is currently emitting chunks of a scenario text line.
    /// Cleared by newline handling and reset after each line-start dispatch.
    in_text_line: bool = false,
    /// Nesting depth of `{...}` interpolations opened from within a scenario
    /// text line. While > 0 the lexer tokenizes logic-mode tokens; a matching
    /// `}` decrements and we resume text-line reading.
    interp_depth: u32 = 0,

    pub fn init(
        source: []const u8,
        diagnostics: *diagnostic.DiagnosticList,
        initial_mode: Mode,
    ) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 1,
            .diagnostics = diagnostics,
            .prev_was_newline = true, // beginning of file is effectively a line start
            .mode = initial_mode,
        };
    }

    pub fn next(self: *Lexer) Token {
        // When emitting chunks of a scenario text line, the next piece is
        // either another text chunk or the `{` of an interpolation.
        if (self.mode == .scenario and self.in_text_line and self.interp_depth == 0) {
            return self.continueTextLine();
        }

        self.skipWhitespace();

        if (self.isAtEnd()) {
            return self.makeSimpleToken(.eof);
        }

        const start = self.currentLocation();
        const c = self.advance();

        // Comments
        if (c == '/') {
            if (self.peek() == '/') {
                self.skipLineComment();
                return self.next();
            }
            if (self.peek() == '*') {
                self.skipBlockComment();
                return self.next();
            }
        }

        // Newlines
        if (c == '\n') {
            self.in_text_line = false;
            return self.handleNewline(start);
        }
        if (c == '\r') {
            if (self.peek() == '\n') _ = self.advance();
            self.in_text_line = false;
            return self.handleNewline(start);
        }

        const was_at_line_start = self.prev_was_newline;
        self.prev_was_newline = false;

        // Scenario-mode line-start dispatch
        if (self.mode == .scenario and was_at_line_start and self.interp_depth == 0) {
            if (c == '@') {
                return self.readDirective(start);
            }
            // Any other first char begins a scenario text line.
            self.in_text_line = true;
            return self.readTextChunk(start);
        }

        // String literals
        if (c == '"') {
            return self.readString(start);
        }

        // Number literals
        if (isDigit(c)) {
            return self.readNumber(start);
        }

        // Identifiers and keywords
        if (isAlpha(c)) {
            return self.readIdentifier(start);
        }

        // Track interpolation braces so we can resume scenario text after `}`.
        if (c == '{' and self.mode == .scenario and self.in_text_line) {
            self.interp_depth += 1;
            return self.makeTokenWithLexeme(.lbrace, start, self.source[start.offset..self.pos]);
        }
        if (c == '}' and self.interp_depth > 0) {
            self.interp_depth -= 1;
            return self.makeTokenWithLexeme(.rbrace, start, self.source[start.offset..self.pos]);
        }

        // Operators and delimiters
        return self.readOperator(c, start);
    }

    /// Read a scenario directive after the leading '@' has been consumed.
    fn readDirective(self: *Lexer, start: SourceLocation) Token {
        const name_start = self.pos;
        while (!self.isAtEnd() and isAlphaNumeric(self.peek().?)) {
            _ = self.advance();
        }
        if (self.pos == name_start) {
            self.diagnostics.addError(.lexer, .{
                .start = start,
                .end = self.currentLocation(),
            }, "expected directive name after '@'");
            return self.makeTokenWithLexeme(.invalid, start, self.source[start.offset..self.pos]);
        }
        return self.makeTokenWithLexeme(.at_directive, start, self.source[name_start..self.pos]);
    }

    /// Read a text chunk whose first character has already been consumed.
    fn readTextChunk(self: *Lexer, start: SourceLocation) Token {
        const start_pos = start.offset;
        while (!self.isAtEnd()) {
            const ch = self.peek().?;
            if (ch == '{' or ch == '\n' or ch == '\r') break;
            _ = self.advance();
        }
        return self.makeTokenWithLexeme(.text_chunk, start, self.source[start_pos..self.pos]);
    }

    /// Continue a scenario text line at the current position. Emits the next
    /// token (text chunk, `{` interpolation, or newline).
    fn continueTextLine(self: *Lexer) Token {
        if (self.isAtEnd()) {
            self.in_text_line = false;
            return self.makeSimpleToken(.eof);
        }
        const start = self.currentLocation();
        const ch = self.peek().?;
        if (ch == '\n' or ch == '\r') {
            _ = self.advance();
            if (ch == '\r' and self.peek() == '\n') _ = self.advance();
            self.in_text_line = false;
            return self.handleNewline(start);
        }
        if (ch == '{') {
            _ = self.advance();
            self.interp_depth += 1;
            return self.makeTokenWithLexeme(.lbrace, start, self.source[start.offset..self.pos]);
        }
        return self.readTextChunk(start);
    }

    fn handleNewline(self: *Lexer, start: SourceLocation) Token {
        // Collapse consecutive newlines
        if (self.prev_was_newline) {
            self.skipNewlines();
            return self.next();
        }
        self.prev_was_newline = true;
        self.skipNewlines();
        return self.makeToken(.newline, start);
    }

    fn skipNewlines(self: *Lexer) void {
        while (!self.isAtEnd()) {
            self.skipWhitespace();
            if (self.peek() == '\n') {
                _ = self.advance();
            } else if (self.peek() == '\r') {
                _ = self.advance();
                if (self.peek() == '\n') _ = self.advance();
            } else if (self.peek() == '/' and self.peekNext() == '/') {
                self.skipAfterSlash();
                self.skipLineComment();
            } else if (self.peek() == '/' and self.peekNext() == '*') {
                self.skipAfterSlash();
                self.skipBlockComment();
            } else {
                break;
            }
        }
    }

    fn skipAfterSlash(self: *Lexer) void {
        _ = self.advance(); // skip '/'
    }

    fn readString(self: *Lexer, start: SourceLocation) Token {
        const start_pos = start.offset;

        while (!self.isAtEnd()) {
            const ch = self.peek().?;
            if (ch == '\n' or ch == '\r') {
                self.diagnostics.addError(.lexer, .{
                    .start = start,
                    .end = self.currentLocation(),
                }, "unterminated string literal");
                return self.makeTokenWithLexeme(.invalid, start, self.source[start_pos..self.pos]);
            }
            if (ch == '\\') {
                _ = self.advance(); // backslash
                if (!self.isAtEnd()) _ = self.advance(); // escaped char
                continue;
            }
            if (ch == '"') {
                _ = self.advance(); // closing quote
                return self.makeTokenWithLexeme(.string_literal, start, self.source[start_pos..self.pos]);
            }
            _ = self.advance();
        }

        self.diagnostics.addError(.lexer, .{
            .start = start,
            .end = self.currentLocation(),
        }, "unterminated string literal");
        return self.makeTokenWithLexeme(.invalid, start, self.source[start_pos..self.pos]);
    }

    fn readNumber(self: *Lexer, start: SourceLocation) Token {
        const start_pos = start.offset;

        // Check for hex (0x) or binary (0b)
        if (self.source[start_pos] == '0' and !self.isAtEnd()) {
            if (self.peek() == 'x' or self.peek() == 'X') {
                _ = self.advance(); // skip 'x'
                if (self.isAtEnd() or !isHexDigit(self.peek().?)) {
                    self.diagnostics.addError(.lexer, .{
                        .start = start,
                        .end = self.currentLocation(),
                    }, "expected hex digits after '0x'");
                    return self.makeTokenWithLexeme(.invalid, start, self.source[start_pos..self.pos]);
                }
                while (!self.isAtEnd() and isHexDigit(self.peek().?)) {
                    _ = self.advance();
                }
                return self.makeTokenWithLexeme(.int_literal, start, self.source[start_pos..self.pos]);
            }
            if (self.peek() == 'b' or self.peek() == 'B') {
                _ = self.advance(); // skip 'b'
                if (self.isAtEnd() or !isBinDigit(self.peek().?)) {
                    self.diagnostics.addError(.lexer, .{
                        .start = start,
                        .end = self.currentLocation(),
                    }, "expected binary digits after '0b'");
                    return self.makeTokenWithLexeme(.invalid, start, self.source[start_pos..self.pos]);
                }
                while (!self.isAtEnd() and isBinDigit(self.peek().?)) {
                    _ = self.advance();
                }
                return self.makeTokenWithLexeme(.int_literal, start, self.source[start_pos..self.pos]);
            }
        }

        // Decimal digits
        while (!self.isAtEnd() and isDigit(self.peek().?)) {
            _ = self.advance();
        }

        // Check for float (digit followed by '.' followed by digit, but not '..')
        if (!self.isAtEnd() and self.peek() == '.') {
            if (self.peekNext() != null and self.peekNext().? == '.') {
                // This is the range operator '..', not a float
                return self.makeTokenWithLexeme(.int_literal, start, self.source[start_pos..self.pos]);
            }
            if (self.peekNext() != null and isDigit(self.peekNext().?)) {
                _ = self.advance(); // skip '.'
                while (!self.isAtEnd() and isDigit(self.peek().?)) {
                    _ = self.advance();
                }
                return self.makeTokenWithLexeme(.float_literal, start, self.source[start_pos..self.pos]);
            }
        }

        return self.makeTokenWithLexeme(.int_literal, start, self.source[start_pos..self.pos]);
    }

    fn readIdentifier(self: *Lexer, start: SourceLocation) Token {
        const start_pos = start.offset;

        while (!self.isAtEnd() and isAlphaNumeric(self.peek().?)) {
            _ = self.advance();
        }

        const lexeme = self.source[start_pos..self.pos];
        const tag = token.lookupIdent(lexeme);
        return self.makeTokenWithLexeme(tag, start, lexeme);
    }

    fn readOperator(self: *Lexer, c: u8, start: SourceLocation) Token {
        const start_pos = start.offset;

        switch (c) {
            '+' => {
                if (self.match('=')) return self.makeTokenWithLexeme(.plus_assign, start, self.source[start_pos..self.pos]);
                return self.makeTokenWithLexeme(.plus, start, self.source[start_pos..self.pos]);
            },
            '-' => {
                if (self.match('=')) return self.makeTokenWithLexeme(.minus_assign, start, self.source[start_pos..self.pos]);
                if (self.match('>')) return self.makeTokenWithLexeme(.arrow, start, self.source[start_pos..self.pos]);
                return self.makeTokenWithLexeme(.minus, start, self.source[start_pos..self.pos]);
            },
            '*' => {
                if (self.match('=')) return self.makeTokenWithLexeme(.star_assign, start, self.source[start_pos..self.pos]);
                return self.makeTokenWithLexeme(.star, start, self.source[start_pos..self.pos]);
            },
            '/' => {
                if (self.match('=')) return self.makeTokenWithLexeme(.slash_assign, start, self.source[start_pos..self.pos]);
                return self.makeTokenWithLexeme(.slash, start, self.source[start_pos..self.pos]);
            },
            '%' => {
                if (self.match('=')) return self.makeTokenWithLexeme(.percent_assign, start, self.source[start_pos..self.pos]);
                return self.makeTokenWithLexeme(.percent, start, self.source[start_pos..self.pos]);
            },
            '=' => {
                if (self.match('=')) return self.makeTokenWithLexeme(.eq, start, self.source[start_pos..self.pos]);
                return self.makeTokenWithLexeme(.assign, start, self.source[start_pos..self.pos]);
            },
            '!' => {
                if (self.match('=')) return self.makeTokenWithLexeme(.neq, start, self.source[start_pos..self.pos]);
                return self.makeTokenWithLexeme(.not, start, self.source[start_pos..self.pos]);
            },
            '<' => {
                if (self.match('=')) return self.makeTokenWithLexeme(.lte, start, self.source[start_pos..self.pos]);
                return self.makeTokenWithLexeme(.lt, start, self.source[start_pos..self.pos]);
            },
            '>' => {
                if (self.match('=')) return self.makeTokenWithLexeme(.gte, start, self.source[start_pos..self.pos]);
                return self.makeTokenWithLexeme(.gt, start, self.source[start_pos..self.pos]);
            },
            '&' => {
                if (self.match('&')) return self.makeTokenWithLexeme(.@"and", start, self.source[start_pos..self.pos]);
                self.diagnostics.addError(.lexer, .{
                    .start = start,
                    .end = self.currentLocation(),
                }, "unexpected character '&', did you mean '&&'?");
                return self.makeTokenWithLexeme(.invalid, start, self.source[start_pos..self.pos]);
            },
            '|' => {
                if (self.match('|')) return self.makeTokenWithLexeme(.@"or", start, self.source[start_pos..self.pos]);
                self.diagnostics.addError(.lexer, .{
                    .start = start,
                    .end = self.currentLocation(),
                }, "unexpected character '|', did you mean '||'?");
                return self.makeTokenWithLexeme(.invalid, start, self.source[start_pos..self.pos]);
            },
            '.' => {
                if (self.match('.')) return self.makeTokenWithLexeme(.dot_dot, start, self.source[start_pos..self.pos]);
                return self.makeTokenWithLexeme(.dot, start, self.source[start_pos..self.pos]);
            },
            '(' => return self.makeTokenWithLexeme(.lparen, start, self.source[start_pos..self.pos]),
            ')' => return self.makeTokenWithLexeme(.rparen, start, self.source[start_pos..self.pos]),
            '{' => return self.makeTokenWithLexeme(.lbrace, start, self.source[start_pos..self.pos]),
            '}' => return self.makeTokenWithLexeme(.rbrace, start, self.source[start_pos..self.pos]),
            '[' => return self.makeTokenWithLexeme(.lbracket, start, self.source[start_pos..self.pos]),
            ']' => return self.makeTokenWithLexeme(.rbracket, start, self.source[start_pos..self.pos]),
            ',' => return self.makeTokenWithLexeme(.comma, start, self.source[start_pos..self.pos]),
            ':' => return self.makeTokenWithLexeme(.colon, start, self.source[start_pos..self.pos]),
            else => {
                self.diagnostics.addError(.lexer, .{
                    .start = start,
                    .end = self.currentLocation(),
                }, "unexpected character");
                return self.makeTokenWithLexeme(.invalid, start, self.source[start_pos..self.pos]);
            },
        }
    }

    // ---- Low-level helpers ----

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn peek(self: *const Lexer) ?u8 {
        if (self.isAtEnd()) return null;
        return self.source[self.pos];
    }

    fn peekNext(self: *const Lexer) ?u8 {
        if (self.pos + 1 >= self.source.len) return null;
        return self.source[self.pos + 1];
    }

    fn isAtEnd(self: *const Lexer) bool {
        return self.pos >= self.source.len;
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.pos] != expected) return false;
        _ = self.advance();
        return true;
    }

    fn skipWhitespace(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek().?;
            if (c == ' ' or c == '\t') {
                _ = self.advance();
            } else {
                break;
            }
        }
    }

    fn skipLineComment(self: *Lexer) void {
        // We're past the first '/', consume the second '/'
        _ = self.advance();
        while (!self.isAtEnd() and self.peek().? != '\n') {
            _ = self.advance();
        }
    }

    fn skipBlockComment(self: *Lexer) void {
        // We're past the first '/', consume '*'
        _ = self.advance();
        var depth: u32 = 1;
        while (!self.isAtEnd() and depth > 0) {
            if (self.peek() == '*' and self.peekNext() == '/') {
                _ = self.advance();
                _ = self.advance();
                depth -= 1;
            } else if (self.peek() == '/' and self.peekNext() == '*') {
                _ = self.advance();
                _ = self.advance();
                depth += 1;
            } else {
                _ = self.advance();
            }
        }
    }

    fn currentLocation(self: *const Lexer) SourceLocation {
        return .{ .line = self.line, .column = self.column, .offset = self.pos };
    }

    fn makeSimpleToken(self: *const Lexer, tag: Tag) Token {
        const loc = self.currentLocation();
        return .{
            .tag = tag,
            .span = .{ .start = loc, .end = loc },
            .lexeme = "",
        };
    }

    fn makeToken(self: *const Lexer, tag: Tag, start: SourceLocation) Token {
        return .{
            .tag = tag,
            .span = .{ .start = start, .end = self.currentLocation() },
            .lexeme = self.source[start.offset..self.pos],
        };
    }

    fn makeTokenWithLexeme(self: *const Lexer, tag: Tag, start: SourceLocation, lexeme: []const u8) Token {
        return .{
            .tag = tag,
            .span = .{ .start = start, .end = self.currentLocation() },
            .lexeme = lexeme,
        };
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isBinDigit(c: u8) bool {
    return c == '0' or c == '1';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isAlphaNumeric(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

// ---- Helper for tests ----

fn collectTokens(source: []const u8, allocator: std.mem.Allocator) !struct { tokens: std.ArrayList(Token), diags: diagnostic.DiagnosticList } {
    var diags = diagnostic.DiagnosticList.init(allocator);
    var lexer = Lexer.init(source, &diags, .logic);
    var tokens: std.ArrayList(Token) = .empty;

    while (true) {
        const tok = lexer.next();
        try tokens.append(allocator, tok);
        if (tok.tag == .eof) break;
    }

    return .{ .tokens = tokens, .diags = diags };
}

fn expectTags(source: []const u8, expected: []const Tag) !void {
    const allocator = std.testing.allocator;
    var result = try collectTokens(source, allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    if (result.tokens.items.len != expected.len) {
        std.debug.print("Expected {d} tokens, got {d}\n", .{ expected.len, result.tokens.items.len });
        for (result.tokens.items) |tok| {
            std.debug.print("  {s} '{s}'\n", .{ @tagName(tok.tag), tok.lexeme });
        }
        return error.TestUnexpectedResult;
    }

    for (expected, 0..) |exp, i| {
        if (result.tokens.items[i].tag != exp) {
            std.debug.print("Token {d}: expected {s}, got {s} '{s}'\n", .{
                i,
                @tagName(exp),
                @tagName(result.tokens.items[i].tag),
                result.tokens.items[i].lexeme,
            });
            return error.TestUnexpectedResult;
        }
    }
}

// ---- Tests ----

test "empty source returns EOF" {
    try expectTags("", &.{.eof});
}

test "whitespace only returns EOF" {
    try expectTags("   \t  ", &.{.eof});
}

test "keywords" {
    try expectTags("let fn if else elif for while return break continue goto true false null state import from in\n", &.{
        .kw_let, .kw_fn, .kw_if, .kw_else, .kw_elif, .kw_for, .kw_while, .kw_return,
        .kw_break, .kw_continue, .kw_goto, .kw_true, .kw_false, .kw_null, .kw_state,
        .kw_import, .kw_from, .kw_in, .newline, .eof,
    });
}

test "identifiers" {
    try expectTags("foo _bar abc123\n", &.{
        .identifier, .identifier, .identifier, .newline, .eof,
    });

    const allocator = std.testing.allocator;
    var result = try collectTokens("foo _bar abc123\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    try std.testing.expectEqualStrings("foo", result.tokens.items[0].lexeme);
    try std.testing.expectEqualStrings("_bar", result.tokens.items[1].lexeme);
    try std.testing.expectEqualStrings("abc123", result.tokens.items[2].lexeme);
}

test "integer literals" {
    try expectTags("42 0 100\n", &.{
        .int_literal, .int_literal, .int_literal, .newline, .eof,
    });
}

test "hex literals" {
    try expectTags("0xFF 0x1A\n", &.{
        .int_literal, .int_literal, .newline, .eof,
    });

    const allocator = std.testing.allocator;
    var result = try collectTokens("0xFF\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    try std.testing.expectEqualStrings("0xFF", result.tokens.items[0].lexeme);
}

test "binary literals" {
    try expectTags("0b1010 0b0\n", &.{
        .int_literal, .int_literal, .newline, .eof,
    });
}

test "float literals" {
    try expectTags("3.14 0.5 100.0\n", &.{
        .float_literal, .float_literal, .float_literal, .newline, .eof,
    });
}

test "range vs float disambiguation" {
    // 0..10 should be int, dot_dot, int (not a float)
    try expectTags("0..10\n", &.{
        .int_literal, .dot_dot, .int_literal, .newline, .eof,
    });
}

test "string literals" {
    try expectTags("\"hello\" \"world\"\n", &.{
        .string_literal, .string_literal, .newline, .eof,
    });

    const allocator = std.testing.allocator;
    var result = try collectTokens("\"hello\"\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    try std.testing.expectEqualStrings("\"hello\"", result.tokens.items[0].lexeme);
}

test "string with escapes" {
    try expectTags("\"with \\\"escape\\\"\"\n", &.{
        .string_literal, .newline, .eof,
    });
}

test "arithmetic operators" {
    try expectTags("+ - * / %\n", &.{
        .plus, .minus, .star, .slash, .percent, .newline, .eof,
    });
}

test "assignment operators" {
    try expectTags("= += -= *= /= %=\n", &.{
        .assign, .plus_assign, .minus_assign, .star_assign, .slash_assign, .percent_assign, .newline, .eof,
    });
}

test "comparison operators" {
    try expectTags("== != < > <= >=\n", &.{
        .eq, .neq, .lt, .gt, .lte, .gte, .newline, .eof,
    });
}

test "logical operators" {
    try expectTags("&& || !\n", &.{
        .@"and", .@"or", .not, .newline, .eof,
    });
}

test "delimiters" {
    try expectTags("( ) { } [ ] , : ->\n", &.{
        .lparen, .rparen, .lbrace, .rbrace, .lbracket, .rbracket,
        .comma, .colon, .arrow, .newline, .eof,
    });
}

test "dot vs dot_dot" {
    try expectTags("obj.field 0..10\n", &.{
        .identifier, .dot, .identifier, .int_literal, .dot_dot, .int_literal, .newline, .eof,
    });
}

test "line comment is skipped" {
    try expectTags("foo // this is a comment\nbar\n", &.{
        .identifier, .newline, .identifier, .newline, .eof,
    });
}

test "block comment is skipped" {
    try expectTags("foo /* comment */ bar\n", &.{
        .identifier, .identifier, .newline, .eof,
    });
}

test "nested block comments" {
    try expectTags("foo /* outer /* inner */ outer */ bar\n", &.{
        .identifier, .identifier, .newline, .eof,
    });
}

test "consecutive newlines collapse" {
    try expectTags("foo\n\n\nbar\n", &.{
        .identifier, .newline, .identifier, .newline, .eof,
    });
}

test "let statement tokens" {
    try expectTags("let x = 42 + 3\n", &.{
        .kw_let, .identifier, .assign, .int_literal, .plus, .int_literal, .newline, .eof,
    });
}

test "function declaration tokens" {
    try expectTags("fn add(a, b) {\n  return a + b\n}\n", &.{
        .kw_fn, .identifier, .lparen, .identifier, .comma, .identifier, .rparen,
        .lbrace, .newline, .kw_return, .identifier, .plus, .identifier, .newline,
        .rbrace, .newline, .eof,
    });
}

test "if statement tokens" {
    try expectTags("if x > 0 {\n  x\n}\n", &.{
        .kw_if, .identifier, .gt, .int_literal, .lbrace, .newline,
        .identifier, .newline, .rbrace, .newline, .eof,
    });
}

test "for range tokens" {
    try expectTags("for i in 0..10 {\n}\n", &.{
        .kw_for, .identifier, .kw_in, .int_literal, .dot_dot, .int_literal,
        .lbrace, .newline, .rbrace, .newline, .eof,
    });
}

test "source location tracking" {
    const allocator = std.testing.allocator;
    var result = try collectTokens("let x\n= 42\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    // "let" at line 1, column 1
    try std.testing.expectEqual(@as(u32, 1), result.tokens.items[0].span.start.line);
    try std.testing.expectEqual(@as(u32, 1), result.tokens.items[0].span.start.column);

    // "x" at line 1, column 5
    try std.testing.expectEqual(@as(u32, 1), result.tokens.items[1].span.start.line);
    try std.testing.expectEqual(@as(u32, 5), result.tokens.items[1].span.start.column);

    // newline

    // "=" at line 2, column 1
    try std.testing.expectEqual(@as(u32, 2), result.tokens.items[3].span.start.line);
    try std.testing.expectEqual(@as(u32, 1), result.tokens.items[3].span.start.column);

    // "42" at line 2, column 3
    try std.testing.expectEqual(@as(u32, 2), result.tokens.items[4].span.start.line);
    try std.testing.expectEqual(@as(u32, 3), result.tokens.items[4].span.start.column);
}

test "unterminated string reports error" {
    const allocator = std.testing.allocator;
    var result = try collectTokens("\"hello\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    try std.testing.expect(result.diags.hasErrors());
    try std.testing.expectEqual(Tag.invalid, result.tokens.items[0].tag);
}

test "unexpected character reports error" {
    const allocator = std.testing.allocator;
    var result = try collectTokens("@\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    try std.testing.expect(result.diags.hasErrors());
    try std.testing.expectEqual(Tag.invalid, result.tokens.items[0].tag);
}

test "single & reports error with suggestion" {
    const allocator = std.testing.allocator;
    var result = try collectTokens("&\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    try std.testing.expect(result.diags.hasErrors());
}

// ---- Scenario-mode tests ----

fn collectScenarioTokens(source: []const u8, allocator: std.mem.Allocator) !struct { tokens: std.ArrayList(Token), diags: diagnostic.DiagnosticList } {
    var diags = diagnostic.DiagnosticList.init(allocator);
    var lexer = Lexer.init(source, &diags, .scenario);
    var tokens: std.ArrayList(Token) = .empty;
    while (true) {
        const tok = lexer.next();
        try tokens.append(allocator, tok);
        if (tok.tag == .eof) break;
    }
    return .{ .tokens = tokens, .diags = diags };
}

test "scenario: plain text line becomes a single text_chunk" {
    const allocator = std.testing.allocator;
    var result = try collectScenarioTokens("Hello world\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    try std.testing.expectEqual(Tag.text_chunk, result.tokens.items[0].tag);
    try std.testing.expectEqualStrings("Hello world", result.tokens.items[0].lexeme);
    try std.testing.expectEqual(Tag.newline, result.tokens.items[1].tag);
    try std.testing.expectEqual(Tag.eof, result.tokens.items[2].tag);
}

test "scenario: @speaker directive yields at_directive + identifier" {
    const allocator = std.testing.allocator;
    var result = try collectScenarioTokens("@speaker Alice\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    try std.testing.expectEqual(Tag.at_directive, result.tokens.items[0].tag);
    try std.testing.expectEqualStrings("speaker", result.tokens.items[0].lexeme);
    try std.testing.expectEqual(Tag.identifier, result.tokens.items[1].tag);
    try std.testing.expectEqualStrings("Alice", result.tokens.items[1].lexeme);
    try std.testing.expectEqual(Tag.newline, result.tokens.items[2].tag);
}

test "scenario: @wait takes int literal" {
    const allocator = std.testing.allocator;
    var result = try collectScenarioTokens("@wait 500\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    try std.testing.expectEqual(Tag.at_directive, result.tokens.items[0].tag);
    try std.testing.expectEqualStrings("wait", result.tokens.items[0].lexeme);
    try std.testing.expectEqual(Tag.int_literal, result.tokens.items[1].tag);
    try std.testing.expectEqualStrings("500", result.tokens.items[1].lexeme);
}

test "scenario: @clear has no args" {
    const allocator = std.testing.allocator;
    var result = try collectScenarioTokens("@clear\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    try std.testing.expectEqual(Tag.at_directive, result.tokens.items[0].tag);
    try std.testing.expectEqualStrings("clear", result.tokens.items[0].lexeme);
    try std.testing.expectEqual(Tag.newline, result.tokens.items[1].tag);
}

test "scenario: text with single interpolation" {
    const allocator = std.testing.allocator;
    var result = try collectScenarioTokens("hello {name}!\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    const tags = result.tokens.items;
    try std.testing.expectEqual(Tag.text_chunk, tags[0].tag);
    try std.testing.expectEqualStrings("hello ", tags[0].lexeme);
    try std.testing.expectEqual(Tag.lbrace, tags[1].tag);
    try std.testing.expectEqual(Tag.identifier, tags[2].tag);
    try std.testing.expectEqualStrings("name", tags[2].lexeme);
    try std.testing.expectEqual(Tag.rbrace, tags[3].tag);
    try std.testing.expectEqual(Tag.text_chunk, tags[4].tag);
    try std.testing.expectEqualStrings("!", tags[4].lexeme);
    try std.testing.expectEqual(Tag.newline, tags[5].tag);
}

test "scenario: text with multiple interpolations" {
    const allocator = std.testing.allocator;
    var result = try collectScenarioTokens("a{x}b{y}c\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    const tags = result.tokens.items;
    try std.testing.expectEqual(Tag.text_chunk, tags[0].tag);
    try std.testing.expectEqualStrings("a", tags[0].lexeme);
    try std.testing.expectEqual(Tag.lbrace, tags[1].tag);
    try std.testing.expectEqual(Tag.identifier, tags[2].tag);
    try std.testing.expectEqual(Tag.rbrace, tags[3].tag);
    try std.testing.expectEqual(Tag.text_chunk, tags[4].tag);
    try std.testing.expectEqualStrings("b", tags[4].lexeme);
    try std.testing.expectEqual(Tag.lbrace, tags[5].tag);
    try std.testing.expectEqual(Tag.identifier, tags[6].tag);
    try std.testing.expectEqual(Tag.rbrace, tags[7].tag);
    try std.testing.expectEqual(Tag.text_chunk, tags[8].tag);
    try std.testing.expectEqualStrings("c", tags[8].lexeme);
}

test "scenario: blank lines between directives" {
    const allocator = std.testing.allocator;
    var result = try collectScenarioTokens("@clear\n\n@wait 100\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    try std.testing.expectEqual(Tag.at_directive, result.tokens.items[0].tag);
    try std.testing.expectEqualStrings("clear", result.tokens.items[0].lexeme);
    try std.testing.expectEqual(Tag.newline, result.tokens.items[1].tag);
    try std.testing.expectEqual(Tag.at_directive, result.tokens.items[2].tag);
    try std.testing.expectEqualStrings("wait", result.tokens.items[2].lexeme);
    try std.testing.expectEqual(Tag.int_literal, result.tokens.items[3].tag);
}

test "scenario: mixed text line and directive" {
    const allocator = std.testing.allocator;
    var result = try collectScenarioTokens("Hello\n@speaker Bob\nHow are you?\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    const items = result.tokens.items;
    try std.testing.expectEqual(Tag.text_chunk, items[0].tag);
    try std.testing.expectEqualStrings("Hello", items[0].lexeme);
    try std.testing.expectEqual(Tag.newline, items[1].tag);
    try std.testing.expectEqual(Tag.at_directive, items[2].tag);
    try std.testing.expectEqualStrings("speaker", items[2].lexeme);
    try std.testing.expectEqual(Tag.identifier, items[3].tag);
    try std.testing.expectEqual(Tag.newline, items[4].tag);
    try std.testing.expectEqual(Tag.text_chunk, items[5].tag);
    try std.testing.expectEqualStrings("How are you?", items[5].lexeme);
}

test "scenario: bare @ is an error" {
    const allocator = std.testing.allocator;
    var result = try collectScenarioTokens("@\n", allocator);
    defer result.tokens.deinit(allocator);
    defer result.diags.deinit();

    try std.testing.expect(result.diags.hasErrors());
}
