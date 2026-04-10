const std = @import("std");
const token = @import("token.zig");

pub const Span = token.Span;

pub const Severity = enum {
    @"error",
    warning,
    note,
};

pub const Phase = enum {
    lexer,
    parser,
    codegen,
    runtime,
};

pub const Diagnostic = struct {
    message: []const u8,
    span: Span,
    severity: Severity,
    phase: Phase,
};

pub const DiagnosticList = struct {
    items: std.ArrayList(Diagnostic) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DiagnosticList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DiagnosticList) void {
        self.items.deinit(self.allocator);
    }

    pub fn addError(self: *DiagnosticList, phase: Phase, span: Span, message: []const u8) void {
        self.items.append(self.allocator, .{
            .message = message,
            .span = span,
            .severity = .@"error",
            .phase = phase,
        }) catch {};
    }

    pub fn addWarning(self: *DiagnosticList, phase: Phase, span: Span, message: []const u8) void {
        self.items.append(self.allocator, .{
            .message = message,
            .span = span,
            .severity = .warning,
            .phase = phase,
        }) catch {};
    }

    pub fn hasErrors(self: *const DiagnosticList) bool {
        for (self.items.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    pub fn format(
        self: *const DiagnosticList,
        file_name: []const u8,
        writer: anytype,
    ) !void {
        for (self.items.items) |d| {
            const severity_str = switch (d.severity) {
                .@"error" => "error",
                .warning => "warning",
                .note => "note",
            };
            const phase_str = switch (d.phase) {
                .lexer => "lexer",
                .parser => "parser",
                .codegen => "codegen",
                .runtime => "runtime",
            };
            try writer.print("{s}[{s}]: {s}\n  --> {s}:{d}:{d}\n", .{
                severity_str,
                phase_str,
                d.message,
                file_name,
                d.span.start.line,
                d.span.start.column,
            });
        }
    }
};

test "DiagnosticList basic operations" {
    const allocator = std.testing.allocator;
    var diags = DiagnosticList.init(allocator);
    defer diags.deinit();

    try std.testing.expect(!diags.hasErrors());

    const span = Span{
        .start = .{ .line = 1, .column = 5, .offset = 4 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };
    diags.addError(.lexer, span, "unterminated string");
    try std.testing.expect(diags.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), diags.items.items.len);
}
