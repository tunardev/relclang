pub const file_name = "relastic_rt.zig";

pub const source =
    \\const std = @import("std");
    \\
    \\pub const Error = error{WriteFailed};
    \\
    \\var io_instance: ?std.Io = null;
    \\
    \\pub fn init(io: std.Io) void {
    \\    io_instance = io;
    \\}
    \\
    \\pub fn printLineInt(v: i64) Error!void {
    \\    const io = io_instance orelse return error.WriteFailed;
    \\    var buf: [64]u8 = undefined;
    \\    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    \\    const w = &fw.interface;
    \\    w.print("{d}\n", .{v}) catch return error.WriteFailed;
    \\    w.flush() catch return error.WriteFailed;
    \\}
    \\
    \\pub fn printLineBool(v: bool) Error!void {
    \\    return printLine(if (v) "true" else "false");
    \\}
    \\
    \\pub fn printLine(s: []const u8) Error!void {
    \\    const io = io_instance orelse return error.WriteFailed;
    \\    var buf: [4096]u8 = undefined;
    \\    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    \\    const w = &fw.interface;
    \\    w.writeAll(s) catch return error.WriteFailed;
    \\    w.writeByte('\n') catch return error.WriteFailed;
    \\    w.flush() catch return error.WriteFailed;
    \\}
    \\
;
