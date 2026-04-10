const std = @import("std");
const neru = @import("neru");

const Lexer = neru.compiler.lexer.Lexer;
const Parser = neru.compiler.parser.Parser;
const Compiler = neru.compiler.codegen.Compiler;
const DiagnosticList = neru.compiler.diagnostic.DiagnosticList;
const NodeStore = neru.compiler.ast.NodeStore;
const VM = neru.vm.vm.VM;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    var args = std.process.args();
    _ = args.next(); // skip program name

    const command = args.next() orelse {
        try printUsage(stderr);
        std.process.exit(1);
    };

    if (std.mem.eql(u8, command, "compile")) {
        const file_path = args.next() orelse {
            try stderr.print("error: missing file path\n", .{});
            std.process.exit(1);
        };
        compileFile(allocator, file_path, stdout, stderr) catch |err| {
            try stderr.print("error: {}\n", .{err});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "run")) {
        const file_path = args.next() orelse {
            try stderr.print("error: missing file path\n", .{});
            std.process.exit(1);
        };
        runFile(allocator, file_path, stdout, stderr) catch |err| {
            try stderr.print("error: {}\n", .{err});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(stdout);
    } else {
        try stderr.print("error: unknown command '{s}'\n", .{command});
        try printUsage(stderr);
        std.process.exit(1);
    }
}

fn compileFile(
    parent_allocator: std.mem.Allocator,
    file_path: []const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch |err| {
        try stderr.print("error: cannot read '{s}': {}\n", .{ file_path, err });
        return error.FileNotFound;
    };

    var diags = DiagnosticList.init(allocator);

    var nodes = NodeStore.init(allocator);

    // Lex + Parse
    var lexer = Lexer.init(source, &diags);
    var parser = Parser.init(allocator, &lexer, &nodes, &diags);
    const root = parser.parseProgram() catch {
        try diags.format(file_path, stderr);
        return error.ParseError;
    };

    if (diags.hasErrors()) {
        try diags.format(file_path, stderr);
        return error.ParseError;
    }

    // Codegen
    var compiler = Compiler.init(allocator, &nodes, &diags);
    const module = compiler.compile(root) catch {
        try diags.format(file_path, stderr);
        return error.CompileError;
    };

    if (diags.hasErrors()) {
        try diags.format(file_path, stderr);
        return error.CompileError;
    }

    // Write .neruc file
    const output_path = try replaceExtension(allocator, file_path, ".neruc");

    const out_file = std.fs.cwd().createFile(output_path, .{}) catch |err| {
        try stderr.print("error: cannot create '{s}': {}\n", .{ output_path, err });
        return error.FileNotFound;
    };
    defer out_file.close();

    var out_buffer: [4096]u8 = undefined;
    var out_writer = out_file.writer(&out_buffer);
    module.serialize(&out_writer.interface) catch |err| {
        try stderr.print("error: write failed: {}\n", .{err});
        return error.WriteError;
    };
    out_writer.interface.flush() catch {};

    try stdout.print("compiled: {s} -> {s}\n", .{ file_path, output_path });
}

fn runFile(
    parent_allocator: std.mem.Allocator,
    file_path: []const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch |err| {
        try stderr.print("error: cannot read '{s}': {}\n", .{ file_path, err });
        return error.FileNotFound;
    };

    var diags = DiagnosticList.init(allocator);

    var nodes = NodeStore.init(allocator);

    // Lex + Parse
    var lexer = Lexer.init(source, &diags);
    var parser = Parser.init(allocator, &lexer, &nodes, &diags);
    const root = parser.parseProgram() catch {
        try diags.format(file_path, stderr);
        return error.ParseError;
    };

    if (diags.hasErrors()) {
        try diags.format(file_path, stderr);
        return error.ParseError;
    }

    // Codegen
    var compiler = Compiler.init(allocator, &nodes, &diags);
    const module = compiler.compile(root) catch {
        try diags.format(file_path, stderr);
        return error.CompileError;
    };

    if (diags.hasErrors()) {
        try diags.format(file_path, stderr);
        return error.CompileError;
    }

    // Execute
    var vm = VM.init(allocator);
    vm.load(module);

    const result = vm.execute() catch |err| {
        const line = vm.currentSourceLine();
        try stderr.print("runtime error at line {d}: {}\n", .{ line, err });
        return error.RuntimeError;
    };

    if (result) |val| {
        try val.formatValue(stdout);
        try stdout.print("\n", .{});
    }
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    // Find the last dot
    var dot_pos: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '.') dot_pos = i;
    }
    const base = if (dot_pos) |pos| path[0..pos] else path;
    const result = try allocator.alloc(u8, base.len + new_ext.len);
    @memcpy(result[0..base.len], base);
    @memcpy(result[base.len..], new_ext);
    return result;
}

fn printUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: neru <command> [options]
        \\
        \\Commands:
        \\  compile <file>   Compile a .nerul file to bytecode (.neruc)
        \\  run <file>       Compile and execute a .nerul file
        \\  help             Show this help message
        \\
        \\
    , .{});
}

test "main module compiles" {
    _ = neru;
}
