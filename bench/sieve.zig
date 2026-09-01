const std = @import("std");

fn build(gpa: std.mem.Allocator, limit: i64) !std.ArrayList(i64) {
    var flags: std.ArrayList(i64) = .empty;
    var i: i64 = 0;
    while (i <= limit) : (i += 1) try flags.append(gpa, 1);

    var p: i64 = 2;
    while (p * p <= limit) : (p += 1) {
        if (flags.items[@intCast(p)] == 1) {
            var m = p * p;
            while (m <= limit) : (m += p) flags.items[@intCast(m)] = 0;
        }
    }
    return flags;
}

pub fn main(init: std.process.Init) !void {
    const limit: i64 = 2000000;
    var flags = try build(init.gpa, limit);
    defer flags.deinit(init.gpa);

    var count: i64 = 0;
    var n: i64 = 2;
    while (n <= limit) : (n += 1) {
        if (flags.items[@intCast(n)] == 1) count += 1;
    }
    std.debug.print("{d}\n", .{count});
}
