pub const file_name = "relastic_rt.zig";

pub const source =
    \\const std = @import("std");
    \\
    \\pub const Error = error{ WriteFailed, ReadFailed, OutOfMemory, IndexOutOfBounds, DivisionByZero };
    \\
    \\pub const Allocator = std.mem.Allocator;
    \\
    \\pub fn drop(ptr: anytype) void {
    \\    const T = @TypeOf(ptr.*);
    \\    switch (@typeInfo(T)) {
    \\        .array => for (ptr) |*item| drop(item),
    \\        .@"struct", .@"union" => if (@hasDecl(T, "deinit")) ptr.deinit(),
    \\        else => {},
    \\    }
    \\}
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
    \\var stdin_buf: [4096]u8 = undefined;
    \\var stdin_reader: ?std.Io.File.Reader = null;
    \\
    \\pub fn readLine(gpa: Allocator) Error!String {
    \\    const io = io_instance orelse return error.ReadFailed;
    \\    if (stdin_reader == null) stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    \\    const reader = &stdin_reader.?.interface;
    \\
    \\    var sink: std.Io.Writer.Allocating = .init(gpa);
    \\    errdefer sink.deinit();
    \\    _ = reader.streamDelimiterEnding(&sink.writer, '\n') catch |err| switch (err) {
    \\        error.WriteFailed => return error.OutOfMemory,
    \\        error.ReadFailed => return error.ReadFailed,
    \\    };
    \\    if (reader.bufferedLen() > 0) reader.toss(1);
    \\    if (sink.writer.end > 0 and sink.writer.buffer[sink.writer.end - 1] == '\r') sink.writer.end -= 1;
    \\    return .{ .list = sink.toArrayList(), .gpa = gpa };
    \\}
    \\
    \\pub fn index(len: usize, i: i64) Error!usize {
    \\    if (i < 0 or i >= len) return error.IndexOutOfBounds;
    \\    return @intCast(i);
    \\}
    \\
    \\pub fn div(a: i64, b: i64) Error!i64 {
    \\    if (b == 0) return error.DivisionByZero;
    \\    return @divTrunc(a, b);
    \\}
    \\
    \\pub fn rem(a: i64, b: i64) Error!i64 {
    \\    if (b == 0) return error.DivisionByZero;
    \\    return @rem(a, b);
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
    \\            for (self.list.items) |*item| drop(item);
    \\            self.list.deinit(self.gpa);
    \\        }
    \\
    \\        pub fn push(self: *Self, value: T) Error!void {
    \\            self.list.append(self.gpa, value) catch return error.OutOfMemory;
    \\        }
    \\
    \\        pub fn get(self: *const Self, i: i64) Error!T {
    \\            return self.list.items[try index(self.list.items.len, i)];
    \\        }
    \\
    \\        pub fn ref(self: *const Self, i: i64) Error!*const T {
    \\            return &self.list.items[try index(self.list.items.len, i)];
    \\        }
    \\
    \\        pub fn set(self: *Self, i: i64, value: T) Error!void {
    \\            const slot = &self.list.items[try index(self.list.items.len, i)];
    \\            drop(slot);
    \\            slot.* = value;
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
