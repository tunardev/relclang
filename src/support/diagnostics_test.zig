const std = @import("std");
const source = @import("source.zig");
const model = @import("diag/model.zig");
const render = @import("diag/render.zig");
const Span = source.Span;
const SourceFile = source.SourceFile;
const impl = @import("diagnostics.zig");

const Code = impl.Code;
const Diagnostics = impl.Diagnostics;

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
        .invalid_operand,  .integer_overflow,    .unused_value,
        .missing_return,   .bad_signature,      .unknown_struct,
        .unknown_field,    .missing_field,      .recursive_struct,
        .not_indexable,    .non_exhaustive,     .unreachable_arm,
        .bad_pattern,     .not_assignable,     .immutable_assign,
        .use_after_move,  .move_in_loop,       .borrow_conflict,
        .move_while_borrowed, .cannot_infer,      .unknown_trait,
        .unknown_method,      .missing_impl,
    };
    for (codes, 0..) |a, i| {
        for (codes[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.id(), b.id()));
        }
    }
}
