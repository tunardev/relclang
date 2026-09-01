const std = @import("std");
const source = @import("source.zig");
const diagnostics = @import("diagnostics.zig");
const token = @import("token.zig");

const Token = token.Token;
const Kind = token.Kind;
const Span = source.Span;

pub fn tokenize(
    arena: std.mem.Allocator,
    file: source.SourceFile,
    diags: *diagnostics.Diagnostics,
) ![]const Token {
    var out: std.ArrayList(Token) = .empty;
    const text = file.text;
    var i: u32 = 0;

    while (i < text.len) {
        const c = text[i];

        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }

        if (c == '#') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }

        if (c == '\n') {
            try out.append(arena, .{ .kind = .newline, .span = .{ .start = i, .end = i + 1 } });
            i += 1;
            continue;
        }

        if (isIdentStart(c)) {
            const start = i;
            while (i < text.len and isIdentContinue(text[i])) i += 1;
            const name = text[start..i];
            try out.append(arena, .{
                .kind = keywordOf(name) orelse .ident,
                .span = .{ .start = start, .end = i },
                .value = name,
            });
            continue;
        }

        if (isDigit(c)) {
            const start = i;
            while (i < text.len and (isDigit(text[i]) or text[i] == '_')) i += 1;
            const digits = text[start..i];

            if (i < text.len and isIdentStart(text[i])) {
                const bad: Span = .{ .start = start, .end = i + 1 };
                try diags.err(.invalid_number, bad, "invalid number literal", "digits run straight into a letter", null);
                while (i < text.len and isIdentContinue(text[i])) i += 1;
                try out.append(arena, .{ .kind = .invalid, .span = .{ .start = start, .end = i } });
                continue;
            }

            try out.append(arena, .{
                .kind = .int,
                .span = .{ .start = start, .end = i },
                .value = digits,
            });
            continue;
        }

        if (c == '"') {
            const tok = try lexString(arena, file, diags, &i);
            try out.append(arena, tok);
            continue;
        }

        if (c == '-' and i + 1 < text.len and text[i + 1] == '>') {
            try out.append(arena, .{ .kind = .arrow, .span = .{ .start = i, .end = i + 2 } });
            i += 2;
            continue;
        }

        const punct: ?Kind = switch (c) {
            '(' => .l_paren,
            ')' => .r_paren,
            '{' => .l_brace,
            '}' => .r_brace,
            ',' => .comma,
            ':' => .colon,
            '=' => .equals,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '.' => .dot,
            ';' => .semicolon,
            '[' => .l_bracket,
            ']' => .r_bracket,
            else => null,
        };

        if (punct) |kind| {
            try out.append(arena, .{ .kind = kind, .span = .{ .start = i, .end = i + 1 } });
            i += 1;
            continue;
        }

        const span: Span = .{ .start = i, .end = i + 1 };
        try diags.err(.unexpected_char, span, "unexpected character", "not valid in Relastic source", null);
        try out.append(arena, .{ .kind = .invalid, .span = span });
        i += 1;
    }

    const end: u32 = @intCast(text.len);
    try out.append(arena, .{ .kind = .eof, .span = .{ .start = end, .end = end } });
    return out.toOwnedSlice(arena);
}

fn lexString(
    arena: std.mem.Allocator,
    file: source.SourceFile,
    diags: *diagnostics.Diagnostics,
    i: *u32,
) !Token {
    const text = file.text;
    const start = i.*;
    var pos = start + 1;

    var buf: std.ArrayList(u8) = .empty;

    while (pos < text.len and text[pos] != '"' and text[pos] != '\n') {
        if (text[pos] != '\\') {
            try buf.append(arena, text[pos]);
            pos += 1;
            continue;
        }

        const esc_start = pos;
        pos += 1;
        if (pos >= text.len) break;

        const decoded: ?u8 = switch (text[pos]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '\\' => '\\',
            '"' => '"',
            '0' => 0,
            else => null,
        };

        if (decoded) |byte| {
            try buf.append(arena, byte);
        } else {
            try diags.err(
                .unknown_escape,
                .{ .start = esc_start, .end = pos + 1 },
                "unknown escape sequence",
                "not a recognised escape",
                "valid escapes are \\n \\t \\r \\\\ \\\" \\0",
            );
        }
        pos += 1;
    }

    if (pos >= text.len or text[pos] != '"') {
        const span: Span = .{ .start = start, .end = pos };
        try diags.err(.unterminated_string, span, "unterminated string literal", "string starts here", "add a closing `\"`");
        i.* = pos;
        return .{ .kind = .invalid, .span = span };
    }

    pos += 1;
    i.* = pos;
    return .{
        .kind = .string,
        .span = .{ .start = start, .end = pos },
        .value = try buf.toOwnedSlice(arena),
    };
}

fn keywordOf(name: []const u8) ?Kind {
    if (std.mem.eql(u8, name, "fn")) return .kw_fn;
    if (std.mem.eql(u8, name, "let")) return .kw_let;
    if (std.mem.eql(u8, name, "struct")) return .kw_struct;
    return null;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

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
