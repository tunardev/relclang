const std = @import("std");

pub const version = "0.1.0";

const usage =
    \\relc - the Relastic compiler
    \\
    \\usage:
    \\  relc build <file.rls> [-o <name>]
    \\  relc run <file.rls>
    \\  relc check <file.rls>
    \\  relc emit-zig <file.rls>
    \\  relc version
    \\
;

pub fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const [:0]const u8,
) !u8 {
    _ = arena;
    _ = gpa;

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    defer w.flush() catch {};

    if (argv.len < 2) {
        try w.writeAll(usage);
        return 1;
    }

    const command = argv[1];

    if (std.mem.eql(u8, command, "version")) {
        try w.print("relc {s}\n", .{version});
        return 0;
    }

    try w.writeAll(usage);
    return 1;
}
