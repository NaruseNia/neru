const std = @import("std");
const token = @import("token.zig");
const diagnostic = @import("diagnostic.zig");

pub const Token = token.Token;
pub const Tag = token.Tag;
pub const SourceLocation = token.SourceLocation;
pub const Span = token.Span;

pub const Lexer = struct {
    source: []const u8,
    pos: u32,
    line: u32,
    column: u32,
    diagnostics: *diagnostic.DiagnosticList,

    pub fn init(source: []const u8, diagnostics: *diagnostic.DiagnosticList) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 1,
            .diagnostics = diagnostics,
        };
    }

    pub fn next(self: *Lexer) Token {
        _ = self;
        return .{
            .tag = .eof,
            .span = .{
                .start = .{ .line = 1, .column = 1, .offset = 0 },
                .end = .{ .line = 1, .column = 1, .offset = 0 },
            },
            .lexeme = "",
        };
    }
};

test "Lexer stub returns EOF" {
    var diags = diagnostic.DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    var lexer = Lexer.init("", &diags);
    const tok = lexer.next();
    try std.testing.expectEqual(Tag.eof, tok.tag);
}
