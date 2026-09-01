pub const file_name = "relastic_rt.zig";

pub const source =
    \\const std = @import("std");
    \\
    \\pub const Error = error{ WriteFailed, OutOfMemory };
    \\
    \\pub const Allocator = std.mem.Allocator;
    \\
    \\pub const String = struct {
    \\    list: std.ArrayList(u8),
    \\    gpa: Allocator,
    \\
    \\    pub fn init(gpa: Allocator) String {
    \\        return .{ .list = .empty, .gpa = gpa };
    \\    }
    \\
    \\    pub fn deinit(self: *String) void {
    \\        self.list.deinit(self.gpa);
    \\    }
    \\
    \\    pub fn push(self: *String, text: []const u8) Error!void {
    \\        self.list.appendSlice(self.gpa, text) catch return error.OutOfMemory;
    \\    }
    \\
    \\    pub fn pushInt(self: *String, value: i64) Error!void {
    \\        var buf: [24]u8 = undefined;
    \\        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.OutOfMemory;
    \\        return self.push(text);
    \\    }
    \\
    \\    pub fn len(self: *const String) i64 {
    \\        return @intCast(self.list.items.len);
    \\    }
    \\
    \\    pub fn items(self: *const String) []const u8 {
    \\        return self.list.items;
    \\    }
    \\};
    \\
    \\pub fn readLine(gpa: Allocator) Error!String {
    \\    const io = io_instance orelse return error.WriteFailed;
    \\    var out: String = .init(gpa);
    \\    var buf: [4096]u8 = undefined;
    \\    var fr = std.Io.File.stdin().readerStreaming(io, &buf);
    \\    fr.interface.streamDelimiter(&out.list, gpa, '\n') catch |err| switch (err) {
    \\        error.EndOfStream => {},
    \\        else => return error.OutOfMemory,
    \\    };
    \\    return out;
    \\}
    \\
    \\pub fn printLineString(s: *const String) Error!void {
    \\    return printLine(s.items());
    \\}
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
    \\            if (@typeInfo(T) == .@"struct" or @typeInfo(T) == .@"union") {
    \\                if (@hasDecl(T, "deinit")) {
    \\                    for (self.list.items) |*item| item.deinit();
    \\                }
    \\            }
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
    \\        pub fn ref(self: *const Self, index: i64) Error!*const T {
    \\            if (index < 0 or index >= self.list.items.len) return error.OutOfMemory;
    \\            return &self.list.items[@intCast(index)];
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
