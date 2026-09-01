const std = @import("std");
const source = @import("source.zig");

const Span = source.Span;
const SourceFile = source.SourceFile;

pub const Code = enum {
    unexpected_token,
    unterminated_string,
    unknown_escape,
    unknown_function,
    missing_main,
    duplicate_function,
    wrong_arg_count,
    type_mismatch,
    unexpected_char,
    invalid_number,
    duplicate_binding,
    unknown_variable,
    invalid_operand,
    integer_overflow,

    pub fn id(c: Code) []const u8 {
        return switch (c) {
            .unexpected_token => "E0001",
            .unterminated_string => "E0002",
            .unknown_escape => "E0003",
            .unknown_function => "E0004",
            .missing_main => "E0005",
            .duplicate_function => "E0006",
            .wrong_arg_count => "E0007",
            .type_mismatch => "E0008",
            .unexpected_char => "E0009",
            .invalid_number => "E0010",
            .duplicate_binding => "E0011",
            .unknown_variable => "E0012",
            .invalid_operand => "E0013",
            .integer_overflow => "E0014",
        };
    }
};

pub const Severity = enum {
    err,
    warning,
    note,

    pub fn text(s: Severity) []const u8 {
        return switch (s) {
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }
};

pub const Diagnostic = struct {
    severity: Severity,
    code: ?Code,
    message: []const u8,
    span: ?Span,
    label: ?[]const u8,
    help: ?[]const u8,
};

pub const Diagnostics = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(Diagnostic),
    errors: usize,

    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        return .{ .gpa = gpa, .arena = .init(gpa), .list = .empty, .errors = 0 };
    }

    pub fn deinit(d: *Diagnostics) void {
        d.list.deinit(d.gpa);
        d.arena.deinit();
    }

    pub fn fmt(d: *Diagnostics, comptime template: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(d.arena.allocator(), template, args);
    }

    pub fn add(d: *Diagnostics, item: Diagnostic) !void {
        if (item.severity == .err) d.errors += 1;
        try d.list.append(d.gpa, item);
    }

    pub fn err(
        d: *Diagnostics,
        code: Code,
        span: ?Span,
        message: []const u8,
        label: ?[]const u8,
        help: ?[]const u8,
    ) !void {
        try d.add(.{
            .severity = .err,
            .code = code,
            .message = message,
            .span = span,
            .label = label,
            .help = help,
        });
    }

    pub fn hasErrors(d: *const Diagnostics) bool {
        return d.errors > 0;
    }

    pub fn render(d: *const Diagnostics, file: SourceFile, w: *std.Io.Writer) !void {
        for (d.list.items) |item| try renderOne(item, file, w);
    }
};

fn digits(n: u32) usize {
    var count: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) count += 1;
    return count;
}

fn renderOne(item: Diagnostic, file: SourceFile, w: *std.Io.Writer) !void {
    const span = item.span orelse return renderFileLevel(item, file, w);
    const loc = file.locOf(span.start);
    const line_text = file.lineText(loc.line);
    const gutter = digits(loc.line) + 1;

    try w.writeAll(item.severity.text());
    if (item.code) |c| try w.print("[{s}]", .{c.id()});
    try w.print(": {s}\n\n", .{item.message});

    try w.splatByteAll(' ', gutter);
    try w.print("--> {s}:{d}:{d}\n", .{ file.path, loc.line, loc.col });

    try w.splatByteAll(' ', gutter + 1);
    try w.writeAll("|\n");

    try w.print(" {d} | ", .{loc.line});
    for (line_text) |ch| try w.writeByte(if (ch == '\t') ' ' else ch);
    try w.writeByte('\n');

    try w.splatByteAll(' ', gutter + 1);
    try w.writeAll("| ");
    try w.splatByteAll(' ', loc.col - 1);

    const remaining = line_text.len + 1 -| (loc.col - 1);
    const width = @max(@as(usize, 1), @min(span.len(), remaining));
    try w.splatByteAll('^', width);

    if (item.label) |l| try w.print(" {s}", .{l});
    try w.writeByte('\n');

    try w.splatByteAll(' ', gutter + 1);
    try w.writeAll("|\n");

    if (item.help) |h| try w.print("help: {s}\n", .{h});
    try w.writeByte('\n');
}

fn renderFileLevel(item: Diagnostic, file: SourceFile, w: *std.Io.Writer) !void {
    try w.writeAll(item.severity.text());
    if (item.code) |c| try w.print("[{s}]", .{c.id()});
    try w.print(": {s}\n\n", .{item.message});
    try w.print("  --> {s}\n", .{file.path});
    if (item.help) |h| try w.print("\nhelp: {s}\n", .{h});
    try w.writeByte('\n');
}

const testing = std.testing;

fn renderToString(gpa: std.mem.Allocator, d: *Diagnostics, file: source.SourceFile) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try d.render(file, &aw.writer);
    return aw.toOwnedSlice();
}

test "renders caret under the offending span" {
    const gpa = testing.allocator;
    const text = "fn main() {\n    println(\"Hello\"\n}\n";
    const file: source.SourceFile = .{ .path = "hello.rls", .text = text };

    var d: Diagnostics = .init(gpa);
    defer d.deinit();
    try d.err(.unexpected_token, .{ .start = 30, .end = 31 }, "unexpected token", "expected `)`", "add `)` to close the call");

    const out = try renderToString(gpa, &d, file);
    defer gpa.free(out);

    const expected =
        \\error[E0001]: unexpected token
        \\
        \\  --> hello.rls:2:19
        \\   |
        \\ 2 |     println("Hello"
        \\   |                   ^ expected `)`
        \\   |
        \\help: add `)` to close the call
        \\
        \\
    ;
    try testing.expectEqualStrings(expected, out);
}

test "renders without label or help" {
    const gpa = testing.allocator;
    const file: source.SourceFile = .{ .path = "a.rls", .text = "abc\n" };

    var d: Diagnostics = .init(gpa);
    defer d.deinit();
    try d.err(.missing_main, .{ .start = 0, .end = 1 }, "no `main` function found", null, null);

    const out = try renderToString(gpa, &d, file);
    defer gpa.free(out);

    const expected =
        \\error[E0005]: no `main` function found
        \\
        \\  --> a.rls:1:1
        \\   |
        \\ 1 | abc
        \\   | ^
        \\   |
        \\
        \\
    ;
    try testing.expectEqualStrings(expected, out);
}

test "multi-character span widens the caret" {
    const gpa = testing.allocator;
    const file: source.SourceFile = .{ .path = "a.rls", .text = "hello world\n" };

    var d: Diagnostics = .init(gpa);
    defer d.deinit();
    try d.err(.unknown_function, .{ .start = 0, .end = 5 }, "unknown function `hello`", null, null);

    const out = try renderToString(gpa, &d, file);
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "^^^^^") != null);
}

test "tabs render as single spaces so the caret aligns" {
    const gpa = testing.allocator;
    const file: source.SourceFile = .{ .path = "a.rls", .text = "\t\tx\n" };

    var d: Diagnostics = .init(gpa);
    defer d.deinit();
    try d.err(.unexpected_char, .{ .start = 2, .end = 3 }, "unexpected character", null, null);

    const out = try renderToString(gpa, &d, file);
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, " 1 |   x\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "   |   ^\n") != null);
}

test "gutter widens for line numbers past nine" {
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..9) |_| try text.appendSlice(gpa, "x\n");
    try text.appendSlice(gpa, "target\n");

    const file: source.SourceFile = .{ .path = "a.rls", .text = text.items };

    var d: Diagnostics = .init(gpa);
    defer d.deinit();
    try d.err(.unexpected_token, .{ .start = 18, .end = 19 }, "unexpected token", null, null);

    const out = try renderToString(gpa, &d, file);
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "  --> a.rls:10:1") != null);
    try testing.expect(std.mem.indexOf(u8, out, " 10 | target") != null);
}

test "a span at end of file still renders" {
    const gpa = testing.allocator;
    const file: source.SourceFile = .{ .path = "a.rls", .text = "fn main() {" };

    var d: Diagnostics = .init(gpa);
    defer d.deinit();
    try d.err(.unexpected_token, .{ .start = 11, .end = 11 }, "unexpected end of file", "expected `}`", null);

    const out = try renderToString(gpa, &d, file);
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "a.rls:1:12") != null);
    try testing.expect(std.mem.indexOf(u8, out, "^ expected `}`") != null);
}

test "renders every diagnostic in order" {
    const gpa = testing.allocator;
    const file: source.SourceFile = .{ .path = "a.rls", .text = "ab\ncd\n" };

    var d: Diagnostics = .init(gpa);
    defer d.deinit();
    try d.err(.unexpected_char, .{ .start = 0, .end = 1 }, "first problem", null, null);
    try d.err(.unexpected_char, .{ .start = 3, .end = 4 }, "second problem", null, null);

    const out = try renderToString(gpa, &d, file);
    defer gpa.free(out);

    const first = std.mem.indexOf(u8, out, "first problem").?;
    const second = std.mem.indexOf(u8, out, "second problem").?;
    try testing.expect(first < second);
    try testing.expectEqual(@as(usize, 2), d.errors);
}

test "a diagnostic without a span renders no snippet" {
    const gpa = testing.allocator;
    const file: source.SourceFile = .{ .path = "a.rls", .text = "fn helper() {\n}\n" };

    var d: Diagnostics = .init(gpa);
    defer d.deinit();
    try d.err(.missing_main, null, "no `main` function found", null, "add `fn main()`");

    const out = try renderToString(gpa, &d, file);
    defer gpa.free(out);

    const expected =
        \\error[E0005]: no `main` function found
        \\
        \\  --> a.rls
        \\
        \\help: add `fn main()`
        \\
        \\
    ;
    try testing.expectEqualStrings(expected, out);
    try testing.expect(std.mem.indexOf(u8, out, "^") == null);
}

test "fmt allocates a label owned by the diagnostics arena" {
    const gpa = testing.allocator;
    const file: source.SourceFile = .{ .path = "a.rls", .text = "abc\n" };

    var d: Diagnostics = .init(gpa);
    defer d.deinit();

    const label = try d.fmt("expected `{s}`, found `{s}`", .{ "Str", "Void" });
    try d.err(.type_mismatch, .{ .start = 0, .end = 3 }, "argument type mismatch", label, null);

    const out = try renderToString(gpa, &d, file);
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "expected `Str`, found `Void`") != null);
}

test "hasErrors tracks severity" {
    const gpa = testing.allocator;
    var d: Diagnostics = .init(gpa);
    defer d.deinit();
    try testing.expect(!d.hasErrors());
    try d.add(.{ .severity = .note, .code = null, .message = "x", .span = source.Span.zero, .label = null, .help = null });
    try testing.expect(!d.hasErrors());
    try d.err(.missing_main, source.Span.zero, "x", null, null);
    try testing.expect(d.hasErrors());
}

test "every code has a distinct id" {
    const codes = [_]Code{
        .unexpected_token, .unterminated_string, .unknown_escape,
        .unknown_function, .missing_main,        .duplicate_function,
        .wrong_arg_count,  .type_mismatch,       .unexpected_char,
        .invalid_number,   .duplicate_binding,   .unknown_variable,
        .invalid_operand,  .integer_overflow,
    };
    for (codes, 0..) |a, i| {
        for (codes[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.id(), b.id()));
        }
    }
}
