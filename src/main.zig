const std = @import("std");
const neru = @import("neru");

const Lexer = neru.compiler.Lexer;
const Parser = neru.compiler.Parser;
const Compiler = neru.compiler.Compiler;
const DiagnosticList = neru.compiler.DiagnosticList;
const NodeStore = neru.compiler.NodeStore;
const VM = neru.vm.VM;
const Event = neru.runtime.Event;
const Response = neru.runtime.Response;
const DirectiveArg = neru.runtime.DirectiveArg;

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

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage(stdout);
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "compile")) {
        if (args.len < 3) {
            try stderr.print("error: missing file path\n", .{});
            std.process.exit(1);
        }
        compileFile(allocator, args[2], stdout, stderr) catch |err| {
            try stderr.print("error: {}\n", .{err});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "run")) {
        var mock = false;
        var file_path: ?[]const u8 = null;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--mock")) {
                mock = true;
            } else if (file_path == null) {
                file_path = a;
            }
        }
        if (file_path == null) {
            try stderr.print("error: missing file path\n", .{});
            std.process.exit(1);
        }
        runFile(allocator, file_path.?, mock, stdout, stderr) catch |err| {
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
    var lexer = Lexer.init(source, &diags, .logic);
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
    mock: bool,
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
    var lexer = Lexer.init(source, &diags, .logic);
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
    defer vm.deinit();
    vm.load(module);

    if (mock) {
        try runMock(&vm, stdout, stderr);
        return;
    }

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

fn runMock(vm: *VM, stdout: anytype, stderr: anytype) !void {
    while (true) {
        const evt_opt = vm.runUntilEvent() catch |err| {
            const line = vm.currentSourceLine();
            try stderr.print("runtime error at line {d}: {}\n", .{ line, err });
            return error.RuntimeError;
        };
        const evt = evt_opt orelse break;
        const response = try renderMockEvent(evt, stdout);
        vm.resumeWith(response);
    }
}

fn renderMockEvent(evt: Event, stdout: anytype) !Response {
    switch (evt) {
        .text_clear => {
            try stdout.print("[clear]\n", .{});
            return .{ .none = {} };
        },
        .text_display => |td| {
            if (td.speaker) |s| {
                try stdout.print("[text] {s}: {s}\n", .{ s, td.text });
            } else {
                try stdout.print("[text] {s}\n", .{td.text});
            }
            return .{ .text_ack = {} };
        },
        .speaker_change => |sc| {
            if (sc.speaker) |s| {
                try stdout.print("[speaker] {s}\n", .{s});
            } else {
                try stdout.print("[speaker] (none)\n", .{});
            }
            return .{ .none = {} };
        },
        .bg_change => |bg| {
            try stdout.print("[bg] {s}", .{bg.image});
            try writeArgs(stdout, bg.args);
            try stdout.print("\n", .{});
            return .{ .none = {} };
        },
        .sprite_show => |sp| {
            try stdout.print("[show] {s}", .{sp.character});
            try writeArgs(stdout, sp.args);
            try stdout.print("\n", .{});
            return .{ .none = {} };
        },
        .sprite_hide => |sp| {
            try stdout.print("[hide] {s}", .{sp.character});
            try writeArgs(stdout, sp.args);
            try stdout.print("\n", .{});
            return .{ .none = {} };
        },
        .bgm_play => |b| {
            try stdout.print("[bgm] {s}", .{b.track});
            try writeArgs(stdout, b.args);
            try stdout.print("\n", .{});
            return .{ .none = {} };
        },
        .bgm_stop => {
            try stdout.print("[bgm_stop]\n", .{});
            return .{ .none = {} };
        },
        .se_play => |s| {
            try stdout.print("[se] {s}", .{s.sound});
            try writeArgs(stdout, s.args);
            try stdout.print("\n", .{});
            return .{ .none = {} };
        },
        .transition => |t| {
            try stdout.print("[transition] {s}", .{t.kind});
            try writeArgs(stdout, t.args);
            try stdout.print("\n", .{});
            return .{ .none = {} };
        },
        .choice_prompt => |cp| {
            try stdout.print("[choice]\n", .{});
            for (cp.options, 0..) |opt, i| {
                try stdout.print("  {d}) {s} -> {s}\n", .{ i, opt.label, opt.target });
            }
            try stdout.print("  (selecting 0)\n", .{});
            return .{ .choice_selected = 0 };
        },
        .wait => |w| {
            try stdout.print("[wait] {d}ms\n", .{w.ms});
            return .{ .wait_completed = {} };
        },
        .save_point => |sp| {
            try stdout.print("[save_point] {s}\n", .{sp.name});
            return .{ .none = {} };
        },
    }
}

fn writeArgs(stdout: anytype, args: []const DirectiveArg) !void {
    if (args.len == 0) return;
    try stdout.print(" (", .{});
    for (args, 0..) |arg, i| {
        if (i > 0) try stdout.print(", ", .{});
        try stdout.print("{s}=", .{arg.key});
        try arg.value.formatValue(stdout);
    }
    try stdout.print(")", .{});
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
        \\  compile <file>       Compile a .nerul file to bytecode (.neruc)
        \\  run [--mock] <file>  Compile and execute a .nerul file
        \\                       --mock: auto-respond to events, print to stdout
        \\  help                 Show this help message
        \\
        \\
    , .{});
}

test "main module compiles" {
    _ = neru;
}
