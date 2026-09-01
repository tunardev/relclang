const std = @import("std");

pub const Span = struct {
    start: u32,
    end: u32,

    pub const zero: Span = .{ .start = 0, .end = 0 };

    pub fn merge(a: Span, b: Span) Span {
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
        };
    }

    pub fn len(s: Span) u32 {
        return if (s.end > s.start) s.end - s.start else 0;
    }
};

pub const Loc = struct {
    line: u32,
    col: u32,
};

pub const SourceFile = struct {
    path: []const u8,
    text: []const u8,

    pub fn locOf(f: SourceFile, offset: u32) Loc {
        const limit = @min(offset, @as(u32, @intCast(f.text.len)));
        var line: u32 = 1;
        var line_start: u32 = 0;
        var i: u32 = 0;
        while (i < limit) : (i += 1) {
            if (f.text[i] == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        return .{ .line = line, .col = limit - line_start + 1 };
    }

    pub fn lineText(f: SourceFile, line: u32) []const u8 {
        var current: u32 = 1;
        var start: usize = 0;
        var i: usize = 0;
        while (i < f.text.len) : (i += 1) {
            if (f.text[i] != '\n') continue;
            if (current == line) return trimCr(f.text[start..i]);
            current += 1;
            start = i + 1;
        }
        if (current == line) return trimCr(f.text[start..]);
        return "";
    }
};

fn trimCr(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}

test "locOf reports 1-based line and column" {
    const f: SourceFile = .{ .path = "t.rls", .text = "ab\ncd\n" };
    try std.testing.expectEqual(Loc{ .line = 1, .col = 1 }, f.locOf(0));
    try std.testing.expectEqual(Loc{ .line = 1, .col = 2 }, f.locOf(1));
    try std.testing.expectEqual(Loc{ .line = 2, .col = 1 }, f.locOf(3));
    try std.testing.expectEqual(Loc{ .line = 2, .col = 2 }, f.locOf(4));
}

test "locOf at end of input" {
    const f: SourceFile = .{ .path = "t.rls", .text = "ab" };
    try std.testing.expectEqual(Loc{ .line = 1, .col = 3 }, f.locOf(2));
}

test "locOf clamps past end of input" {
    const f: SourceFile = .{ .path = "t.rls", .text = "ab" };
    try std.testing.expectEqual(Loc{ .line = 1, .col = 3 }, f.locOf(99));
}

test "lineText excludes the newline" {
    const f: SourceFile = .{ .path = "t.rls", .text = "ab\ncd\n" };
    try std.testing.expectEqualStrings("ab", f.lineText(1));
    try std.testing.expectEqualStrings("cd", f.lineText(2));
}

test "lineText on final line without trailing newline" {
    const f: SourceFile = .{ .path = "t.rls", .text = "ab\ncd" };
    try std.testing.expectEqualStrings("cd", f.lineText(2));
}

test "lineText strips a trailing carriage return" {
    const f: SourceFile = .{ .path = "t.rls", .text = "ab\r\ncd\r\n" };
    try std.testing.expectEqualStrings("ab", f.lineText(1));
}

test "lineText out of range is empty" {
    const f: SourceFile = .{ .path = "t.rls", .text = "ab\n" };
    try std.testing.expectEqualStrings("", f.lineText(9));
}

test "merge spans covers both" {
    const a: Span = .{ .start = 2, .end = 5 };
    const b: Span = .{ .start = 9, .end = 11 };
    try std.testing.expectEqual(Span{ .start = 2, .end = 11 }, Span.merge(a, b));
}

test "len is zero for an empty or inverted span" {
    try std.testing.expectEqual(@as(u32, 3), (Span{ .start = 1, .end = 4 }).len());
    try std.testing.expectEqual(@as(u32, 0), Span.zero.len());
    try std.testing.expectEqual(@as(u32, 0), (Span{ .start = 5, .end = 2 }).len());
}
