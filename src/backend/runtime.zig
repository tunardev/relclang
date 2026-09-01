pub const file_name = "relastic_rt.zig";

pub const source =
    \\const std = @import("std");
    \\
    \\pub const Error = error{ WriteFailed, OutOfMemory };
    \\
    \\pub const Allocator = std.mem.Allocator;
    \\
    \\pub fn Vec(comptime T: type) type {
    \\    return struct {
    \\        list: std.ArrayList(T),
    \\        gpa: Allocator,
    \\
    \\        const Self = @This();
    \\
    \\        pub fn init(gpa: Allocator) Self {
    \\            return .{ .list = .empty, .gpa = gpa };
    \\        }
    \\
    \\        pub fn deinit(self: *Self) void {
    \\            self.list.deinit(self.gpa);
    \\        }
    \\
    \\        pub fn push(self: *Self, value: T) Error!void {
    \\            self.list.append(self.gpa, value) catch return error.OutOfMemory;
    \\        }
    \\
    \\        pub fn get(self: *const Self, index: i64) Error!T {
    \\            if (index < 0 or index >= self.list.items.len) return error.OutOfMemory;
    \\            return self.list.items[@intCast(index)];
    \\        }
    \\
    \\        pub fn set(self: *Self, index: i64, value: T) Error!void {
    \\            if (index < 0 or index >= self.list.items.len) return error.OutOfMemory;
    \\            self.list.items[@intCast(index)] = value;
    \\        }
    \\
    \\        pub fn len(self: *const Self) i64 {
    \\            return @intCast(self.list.items.len);
    \\        }
    \\    };
    \\}
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
