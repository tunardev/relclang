const std = @import("std");

const Acc = struct {
    total: i64,
    best: i64,

    fn advance(self: *const Acc, n: i64) i64 {
        _ = self;
        return if (@rem(n, 2) == 0) @divTrunc(n, 2) else 3 * n + 1;
    }
};

fn chain(w: *const Acc, start: i64) i64 {
    var n = start;
    var count: i64 = 0;
    while (n != 1) {
        n = w.advance(n);
        count += 1;
    }
    return count;
}

pub fn main() !void {
    const acc = Acc{ .total = 0, .best = 0 };
    var i: i64 = 1;
    var best: i64 = 0;
    var total: i64 = 0;
    while (i < 300000) {
        const c = chain(&acc, i);
        total += c;
        if (c > best) best = c;
        i += 1;
    }
    std.debug.print("{d}\n{d}\n", .{ total, best });
}
