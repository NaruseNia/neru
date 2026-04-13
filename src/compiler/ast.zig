const std = @import("std");
const token = @import("token.zig");
const event = @import("../runtime/event.zig");

pub const DirectiveKind = event.DirectiveKind;

pub const Span = token.Span;
pub const NodeIndex = u32;

pub const Node = union(enum) {
    program: Program,

    // Statements
    let_stmt: LetStmt,
    fn_decl: FnDecl,
    if_stmt: IfStmt,
    for_stmt: ForStmt,
    while_stmt: WhileStmt,
    return_stmt: ReturnStmt,
    break_stmt: BreakStmt,
    continue_stmt: ContinueStmt,
    assign_stmt: AssignStmt,
    expr_stmt: ExprStmt,

    // Scenario
    text_line: TextLine,
    speaker_directive: SpeakerDirective,
    wait_directive: WaitDirective,
    clear_directive: ClearDirective,
    media_directive: MediaDirective,

    // Expressions
    binary_expr: BinaryExpr,
    unary_expr: UnaryExpr,
    call_expr: CallExpr,
    index_expr: IndexExpr,
    member_expr: MemberExpr,
    literal_expr: LiteralExpr,
    identifier_expr: IdentifierExpr,
    array_expr: ArrayExpr,
    map_expr: MapExpr,
    grouped_expr: GroupedExpr,
    range_expr: RangeExpr,

    pub fn span(self: Node) Span {
        return switch (self) {
            .program => |n| n.span,
            .let_stmt => |n| n.span,
            .fn_decl => |n| n.span,
            .if_stmt => |n| n.span,
            .for_stmt => |n| n.span,
            .while_stmt => |n| n.span,
            .return_stmt => |n| n.span,
            .break_stmt => |n| n.span,
            .continue_stmt => |n| n.span,
            .assign_stmt => |n| n.span,
            .expr_stmt => |n| n.span,
            .text_line => |n| n.span,
            .speaker_directive => |n| n.span,
            .wait_directive => |n| n.span,
            .clear_directive => |n| n.span,
            .media_directive => |n| n.span,
            .binary_expr => |n| n.span,
            .unary_expr => |n| n.span,
            .call_expr => |n| n.span,
            .index_expr => |n| n.span,
            .member_expr => |n| n.span,
            .literal_expr => |n| n.span,
            .identifier_expr => |n| n.span,
            .array_expr => |n| n.span,
            .map_expr => |n| n.span,
            .grouped_expr => |n| n.span,
            .range_expr => |n| n.span,
        };
    }
};

pub const Program = struct {
    stmts: []const NodeIndex,
    span: Span,
};

pub const LetStmt = struct {
    name: []const u8,
    value: NodeIndex,
    span: Span,
};

pub const FnDecl = struct {
    name: []const u8,
    params: []const []const u8,
    body: []const NodeIndex,
    span: Span,
};

pub const IfStmt = struct {
    condition: NodeIndex,
    then_body: []const NodeIndex,
    else_if_clauses: []const ElseIfClause,
    else_body: ?[]const NodeIndex,
    span: Span,
};

pub const ElseIfClause = struct {
    condition: NodeIndex,
    body: []const NodeIndex,
};

pub const ForStmt = struct {
    iterator_name: []const u8,
    iterable: NodeIndex,
    body: []const NodeIndex,
    span: Span,
};

pub const WhileStmt = struct {
    condition: NodeIndex,
    body: []const NodeIndex,
    span: Span,
};

pub const ReturnStmt = struct {
    value: ?NodeIndex,
    span: Span,
};

pub const BreakStmt = struct { span: Span };
pub const ContinueStmt = struct { span: Span };

pub const AssignStmt = struct {
    target: NodeIndex,
    op: AssignOp,
    value: NodeIndex,
    span: Span,
};

pub const AssignOp = enum {
    assign,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    percent_assign,
};

pub const ExprStmt = struct {
    expr: NodeIndex,
    span: Span,
};

// ---- Scenario nodes ----

pub const TextSegment = union(enum) {
    /// Literal text chunk (includes whitespace).
    text: []const u8,
    /// Embedded `{expression}` — the expression's NodeIndex.
    expr: NodeIndex,
};

pub const TextLine = struct {
    segments: []const TextSegment,
    span: Span,
};

pub const SpeakerDirective = struct {
    /// Speaker name (identifier lexeme or unquoted string contents).
    name: []const u8,
    span: Span,
};

pub const WaitDirective = struct {
    ms: u32,
    span: Span,
};

pub const ClearDirective = struct {
    span: Span,
};

/// Literal value for a directive option (--key=value).
pub const OptionValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    /// Bare identifier (e.g. `slow`, `center`) — treated as a symbolic string.
    ident: []const u8,
    bool_val: bool,
};

pub const DirectiveOption = struct {
    key: []const u8,
    value: OptionValue,
};

/// Shared node for @bg, @show, @hide, @bgm, @bgm_stop, @se, @transition.
/// `primary` is the positional argument (image path, character, track, etc.)
/// and is null only for @bgm_stop.
pub const MediaDirective = struct {
    kind: DirectiveKind,
    primary: ?[]const u8,
    options: []const DirectiveOption,
    span: Span,
};

pub const BinaryExpr = struct {
    left: NodeIndex,
    op: BinaryOp,
    right: NodeIndex,
    span: Span,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    @"and",
    @"or",
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: NodeIndex,
    span: Span,
};

pub const UnaryOp = enum { negate, not };

pub const CallExpr = struct {
    callee: NodeIndex,
    args: []const NodeIndex,
    span: Span,
};

pub const IndexExpr = struct {
    object: NodeIndex,
    index: NodeIndex,
    span: Span,
};

pub const MemberExpr = struct {
    object: NodeIndex,
    member: []const u8,
    span: Span,
};

pub const LiteralExpr = struct {
    value: LiteralValue,
    span: Span,
};

pub const LiteralValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
    null_val: void,
};

pub const IdentifierExpr = struct {
    name: []const u8,
    span: Span,
};

pub const ArrayExpr = struct {
    elements: []const NodeIndex,
    span: Span,
};

pub const MapExpr = struct {
    entries: []const MapEntry,
    span: Span,
};

pub const MapEntry = struct {
    key: NodeIndex,
    value: NodeIndex,
};

pub const GroupedExpr = struct {
    inner: NodeIndex,
    span: Span,
};

pub const RangeExpr = struct {
    start: NodeIndex,
    end: NodeIndex,
    span: Span,
};

// ---- NodeStore ----

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
