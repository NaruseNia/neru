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
