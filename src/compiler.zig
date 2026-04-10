// Re-export primary types for clean API: neru.compiler.Lexer, neru.compiler.Parser, etc.
pub const Lexer = lexer.Lexer;
pub const Parser = parser.Parser;
pub const ParseError = parser.ParseError;
pub const Compiler = codegen.Compiler;
pub const CompiledModule = codegen.CompiledModule;
pub const DiagnosticList = diagnostic.DiagnosticList;
pub const Diagnostic = diagnostic.Diagnostic;
pub const NodeStore = ast.NodeStore;
pub const Node = ast.Node;
pub const NodeIndex = ast.NodeIndex;
pub const Token = token.Token;
pub const Tag = token.Tag;

// Sub-modules for detailed access
pub const token = @import("compiler/token.zig");
pub const diagnostic = @import("compiler/diagnostic.zig");
pub const lexer = @import("compiler/lexer.zig");
pub const ast = @import("compiler/ast.zig");
pub const parser = @import("compiler/parser.zig");
pub const codegen = @import("compiler/codegen.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
