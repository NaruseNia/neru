const std = @import("std");

pub const SourceLocation = struct {
    line: u32,
    column: u32,
    offset: u32,
};

pub const Span = struct {
    start: SourceLocation,
    end: SourceLocation,
};

pub const Token = struct {
    tag: Tag,
    span: Span,
    lexeme: []const u8,
};

pub const Tag = enum {
    // Keywords
    kw_let,
    kw_fn,
    kw_if,
    kw_else,
    kw_elif,
    kw_for,
    kw_while,
    kw_return,
    kw_break,
    kw_continue,
    kw_goto,
    kw_true,
    kw_false,
    kw_null,
    kw_state,
    kw_import,
    kw_from,
    kw_in,

    // Literals
    int_literal,
    float_literal,
    string_literal,

    // Identifiers
    identifier,

    // Operators
    plus,
    minus,
    star,
    slash,
    percent,
    assign,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    percent_assign,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    @"and",
    @"or",
    not,
    dot,
    dot_dot,

    // Delimiters
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    comma,
    colon,
    arrow,

    // Special
    newline,
    eof,
    invalid,

    pub fn symbol(self: Tag) []const u8 {
        return switch (self) {
            .kw_let => "let",
            .kw_fn => "fn",
            .kw_if => "if",
            .kw_else => "else",
            .kw_elif => "elif",
            .kw_for => "for",
            .kw_while => "while",
            .kw_return => "return",
            .kw_break => "break",
            .kw_continue => "continue",
            .kw_goto => "goto",
            .kw_true => "true",
            .kw_false => "false",
            .kw_null => "null",
            .kw_state => "state",
            .kw_import => "import",
            .kw_from => "from",
            .kw_in => "in",
            .int_literal => "<int>",
            .float_literal => "<float>",
            .string_literal => "<string>",
            .identifier => "<identifier>",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .assign => "=",
            .plus_assign => "+=",
            .minus_assign => "-=",
            .star_assign => "*=",
            .slash_assign => "/=",
            .percent_assign => "%=",
            .eq => "==",
            .neq => "!=",
            .lt => "<",
            .gt => ">",
            .lte => "<=",
            .gte => ">=",
            .@"and" => "&&",
            .@"or" => "||",
            .not => "!",
            .dot => ".",
            .dot_dot => "..",
            .lparen => "(",
            .rparen => ")",
            .lbrace => "{",
            .rbrace => "}",
            .lbracket => "[",
            .rbracket => "]",
            .comma => ",",
            .colon => ":",
            .arrow => "->",
            .newline => "<newline>",
            .eof => "<eof>",
            .invalid => "<invalid>",
        };
    }
};

const keyword_map = std.StaticStringMap(Tag).initComptime(.{
    .{ "let", .kw_let },
    .{ "fn", .kw_fn },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "elif", .kw_elif },
    .{ "for", .kw_for },
    .{ "while", .kw_while },
    .{ "return", .kw_return },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "goto", .kw_goto },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "null", .kw_null },
    .{ "state", .kw_state },
    .{ "import", .kw_import },
    .{ "from", .kw_from },
    .{ "in", .kw_in },
});

pub fn lookupIdent(lexeme: []const u8) Tag {
    return keyword_map.get(lexeme) orelse .identifier;
}

test "lookupIdent returns keyword tags" {
    try std.testing.expectEqual(Tag.kw_let, lookupIdent("let"));
    try std.testing.expectEqual(Tag.kw_fn, lookupIdent("fn"));
    try std.testing.expectEqual(Tag.kw_if, lookupIdent("if"));
    try std.testing.expectEqual(Tag.kw_return, lookupIdent("return"));
    try std.testing.expectEqual(Tag.kw_true, lookupIdent("true"));
    try std.testing.expectEqual(Tag.kw_state, lookupIdent("state"));
    try std.testing.expectEqual(Tag.kw_in, lookupIdent("in"));
}

test "lookupIdent returns identifier for non-keywords" {
    try std.testing.expectEqual(Tag.identifier, lookupIdent("foo"));
    try std.testing.expectEqual(Tag.identifier, lookupIdent("bar_baz"));
    try std.testing.expectEqual(Tag.identifier, lookupIdent("x123"));
}
