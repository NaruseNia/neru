const std = @import("std");
const token = @import("token.zig");

pub const Span = token.Span;
pub const NodeIndex = u32;

pub const Node = union(enum) {
    program: Program,

    pub fn span(self: Node) Span {
        return switch (self) {
            .program => |p| p.span,
        };
    }
};

pub const Program = struct {
    stmts: []const NodeIndex,
    span: Span,
};

pub const NodeStore = struct {
    nodes: std.ArrayList(Node) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NodeStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NodeStore) void {
        self.nodes.deinit(self.allocator);
    }

    pub fn addNode(self: *NodeStore, node: Node) !NodeIndex {
        const index: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return index;
    }

    pub fn getNode(self: *const NodeStore, index: NodeIndex) Node {
        return self.nodes.items[index];
    }
};

test "NodeStore basic operations" {
    var store = NodeStore.init(std.testing.allocator);
    defer store.deinit();

    const zero_span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 1, .offset = 0 },
    };
    const idx = try store.addNode(.{ .program = .{ .stmts = &.{}, .span = zero_span } });
    try std.testing.expectEqual(@as(NodeIndex, 0), idx);

    const node = store.getNode(idx);
    try std.testing.expectEqual(@as(usize, 0), node.program.stmts.len);
}
