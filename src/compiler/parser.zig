const std = @import("std");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");
const diagnostic = @import("diagnostic.zig");

pub const Parser = struct {
    lexer: *lexer_mod.Lexer,
    nodes: *ast.NodeStore,
    diagnostics: *diagnostic.DiagnosticList,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        lexer: *lexer_mod.Lexer,
        nodes: *ast.NodeStore,
        diagnostics: *diagnostic.DiagnosticList,
    ) Parser {
        return .{
            .allocator = allocator,
            .lexer = lexer,
            .nodes = nodes,
            .diagnostics = diagnostics,
        };
    }

    pub fn parseProgram(self: *Parser) !ast.NodeIndex {
        _ = self;
        // TODO: implement full parsing
        return 0;
    }
};

test "Parser stub" {
    const allocator = std.testing.allocator;
    var diags = diagnostic.DiagnosticList.init(allocator);
    defer diags.deinit();

    var lex = lexer_mod.Lexer.init("", &diags);
    var nodes = ast.NodeStore.init(allocator);
    defer nodes.deinit();

    var parser = Parser.init(allocator, &lex, &nodes, &diags);
    _ = &parser;
}
