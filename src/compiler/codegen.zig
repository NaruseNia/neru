const std = @import("std");
const ast = @import("ast.zig");
const opcodes = @import("../vm/opcodes.zig");
const diagnostic = @import("diagnostic.zig");

pub const Compiler = struct {
    nodes: *const ast.NodeStore,
    diagnostics: *diagnostic.DiagnosticList,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        nodes: *const ast.NodeStore,
        diagnostics: *diagnostic.DiagnosticList,
    ) Compiler {
        return .{
            .allocator = allocator,
            .nodes = nodes,
            .diagnostics = diagnostics,
        };
    }
};

test "Compiler stub" {
    const allocator = std.testing.allocator;
    var diags = diagnostic.DiagnosticList.init(allocator);
    defer diags.deinit();

    var nodes = ast.NodeStore.init(allocator);
    defer nodes.deinit();

    const compiler = Compiler.init(allocator, &nodes, &diags);
    _ = compiler;
}
