const std = @import("std");

pub fn main() !void {
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
        return;
    };

    if (std.mem.eql(u8, command, "compile")) {
        const file_path = args.next() orelse {
            try stderr.print("error: missing file path\n", .{});
            try printUsage(stderr);
            return;
        };
        try stdout.print("compile: {s} (not yet implemented)\n", .{file_path});
    } else if (std.mem.eql(u8, command, "run")) {
        const file_path = args.next() orelse {
            try stderr.print("error: missing file path\n", .{});
            try printUsage(stderr);
            return;
        };
        try stdout.print("run: {s} (not yet implemented)\n", .{file_path});
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(stdout);
    } else {
        try stderr.print("error: unknown command '{s}'\n", .{command});
        try printUsage(stderr);
    }
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
    const neru = @import("neru");
    _ = neru;
}
