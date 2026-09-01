const std = @import("std");
const source = @import("../support/source.zig");
const diagnostics = @import("../support/diagnostics.zig");
const token = @import("token.zig");
const Token = token.Token;
const Kind = token.Kind;
const Span = source.Span;
const impl = @import("lexer.zig");

const tokenize = impl.tokenize;

const testing = std.testing;

fn kindsOf(gpa: std.mem.Allocator, text: []const u8) ![]token.Kind {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const toks = try tokenize(arena_state.allocator(), file, &d);
    const out = try gpa.alloc(token.Kind, toks.len);
    for (toks, 0..) |t, i| out[i] = t.kind;
    return out;
}

test "lexes a hello world program" {
    const gpa = testing.allocator;
    const kinds = try kindsOf(gpa, "fn main() {\n    println(\"hi\")\n}\n");
    defer gpa.free(kinds);

    try testing.expectEqualSlices(token.Kind, &.{
        .kw_fn,   .ident,   .l_paren, .r_paren, .l_brace, .newline,
        .ident,   .l_paren, .string,  .r_paren, .newline, .r_brace,
        .newline, .eof,
    }, kinds);
}

test "fn is a keyword but function is an identifier" {
    const gpa = testing.allocator;
    const kinds = try kindsOf(gpa, "fn function");
    defer gpa.free(kinds);
    try testing.expectEqualSlices(token.Kind, &.{ .kw_fn, .ident, .eof }, kinds);
}

test "hash comments run to end of line and keep the newline" {
    const gpa = testing.allocator;
    const kinds = try kindsOf(gpa, "fn # trailing\nmain");
    defer gpa.free(kinds);
    try testing.expectEqualSlices(token.Kind, &.{ .kw_fn, .newline, .ident, .eof }, kinds);
}

test "a comment at end of file needs no newline" {
    const gpa = testing.allocator;
    const kinds = try kindsOf(gpa, "fn # trailing");
    defer gpa.free(kinds);
    try testing.expectEqualSlices(token.Kind, &.{ .kw_fn, .eof }, kinds);
}

test "carriage returns are whitespace" {
    const gpa = testing.allocator;
    const kinds = try kindsOf(gpa, "fn\r\nmain");
    defer gpa.free(kinds);
    try testing.expectEqualSlices(token.Kind, &.{ .kw_fn, .newline, .ident, .eof }, kinds);
}

test "empty input yields only eof" {
    const gpa = testing.allocator;
    const kinds = try kindsOf(gpa, "");
    defer gpa.free(kinds);
    try testing.expectEqualSlices(token.Kind, &.{.eof}, kinds);
}

test "decodes string escapes" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "\"a\\nb\\t\\\\\\\"c\"" };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const toks = try tokenize(arena_state.allocator(), file, &d);
    try testing.expect(!d.hasErrors());
    try testing.expectEqual(token.Kind.string, toks[0].kind);
    try testing.expectEqualStrings("a\nb\t\\\"c", toks[0].value);
}

test "decodes a null escape" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "\"a\\0b\"" };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const toks = try tokenize(arena_state.allocator(), file, &d);
    try testing.expect(!d.hasErrors());
    try testing.expectEqualSlices(u8, &.{ 'a', 0, 'b' }, toks[0].value);
}

test "an empty string literal is valid" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "\"\"" };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const toks = try tokenize(arena_state.allocator(), file, &d);
    try testing.expect(!d.hasErrors());
    try testing.expectEqual(token.Kind.string, toks[0].kind);
    try testing.expectEqualStrings("", toks[0].value);
}

test "identifier value is the identifier text" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "println" };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const toks = try tokenize(arena_state.allocator(), file, &d);
    try testing.expectEqualStrings("println", toks[0].value);
}

test "unterminated string reports E0002" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "\"abc" };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    _ = try tokenize(arena_state.allocator(), file, &d);
    try testing.expect(d.hasErrors());
    try testing.expectEqual(diagnostics.Code.unterminated_string, d.list.items[0].code.?);
}

test "a newline terminates an unterminated string" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "\"abc\nfn" };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const toks = try tokenize(arena_state.allocator(), file, &d);
    try testing.expectEqual(diagnostics.Code.unterminated_string, d.list.items[0].code.?);
    try testing.expectEqual(token.Kind.newline, toks[1].kind);
    try testing.expectEqual(token.Kind.kw_fn, toks[2].kind);
}

test "unknown escape reports E0003" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "\"a\\qb\"" };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    _ = try tokenize(arena_state.allocator(), file, &d);
    try testing.expectEqual(diagnostics.Code.unknown_escape, d.list.items[0].code.?);
}

test "unexpected character reports E0009" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "fn $" };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    _ = try tokenize(arena_state.allocator(), file, &d);
    try testing.expectEqual(diagnostics.Code.unexpected_char, d.list.items[0].code.?);
}

test "spans point at the right source text" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const text = "fn main";
    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const toks = try tokenize(arena_state.allocator(), file, &d);
    try testing.expectEqualStrings("fn", text[toks[0].span.start..toks[0].span.end]);
    try testing.expectEqualStrings("main", text[toks[1].span.start..toks[1].span.end]);
}

test "a string span covers both quotes" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const text = "\"hi\"";
    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const toks = try tokenize(arena_state.allocator(), file, &d);
    try testing.expectEqualStrings("\"hi\"", text[toks[0].span.start..toks[0].span.end]);
}

test "lexes integer literals" {
    const gpa = testing.allocator;
    const kinds = try kindsOf(gpa, "let x = 10");
    defer gpa.free(kinds);
    try testing.expectEqualSlices(token.Kind, &.{ .kw_let, .ident, .equals, .int, .eof }, kinds);
}

test "let is a keyword but letter is an identifier" {
    const gpa = testing.allocator;
    const kinds = try kindsOf(gpa, "let letter");
    defer gpa.free(kinds);
    try testing.expectEqualSlices(token.Kind, &.{ .kw_let, .ident, .eof }, kinds);
}

test "lexes every arithmetic operator" {
    const gpa = testing.allocator;
    const kinds = try kindsOf(gpa, "+ - * / %");
    defer gpa.free(kinds);
    try testing.expectEqualSlices(token.Kind, &.{ .plus, .minus, .star, .slash, .percent, .eof }, kinds);
}

test "lexes a type annotation" {
    const gpa = testing.allocator;
    const kinds = try kindsOf(gpa, "let x: Int = 1");
    defer gpa.free(kinds);
    try testing.expectEqualSlices(token.Kind, &.{ .kw_let, .ident, .colon, .ident, .equals, .int, .eof }, kinds);
}

test "integer literal value is the digit text" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "1_000" };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const toks = try tokenize(arena_state.allocator(), file, &d);
    try testing.expect(!d.hasErrors());
    try testing.expectEqualStrings("1_000", toks[0].value);
}

test "a number running into a letter reports E0010" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "let x = 12abc" };
    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    _ = try tokenize(arena_state.allocator(), file, &d);
    try testing.expect(d.hasErrors());
    try testing.expectEqual(diagnostics.Code.invalid_number, d.list.items[0].code.?);
}

test "operators do not need surrounding spaces" {
    const gpa = testing.allocator;
    const kinds = try kindsOf(gpa, "1+2*3");
    defer gpa.free(kinds);
    try testing.expectEqualSlices(token.Kind, &.{ .int, .plus, .int, .star, .int, .eof }, kinds);
}
