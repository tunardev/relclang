const std = @import("std");
const source = @import("../support/source.zig");
const diagnostics = @import("../support/diagnostics.zig");
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

        if (i + 1 < text.len) {
            const two: ?Kind = switch (c) {
                '=' => if (text[i + 1] == '=') Kind.eq_eq else null,
                '!' => if (text[i + 1] == '=') Kind.bang_eq else null,
                '<' => if (text[i + 1] == '=') Kind.le else null,
                '>' => if (text[i + 1] == '=') Kind.ge else null,
                else => null,
            };
            if (two) |kind| {
                try out.append(arena, .{ .kind = kind, .span = .{ .start = i, .end = i + 2 } });
                i += 2;
                continue;
            }
        }

        if (c == '=' and i + 1 < text.len and text[i + 1] == '>') {
            try out.append(arena, .{ .kind = .fat_arrow, .span = .{ .start = i, .end = i + 2 } });
            i += 2;
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
            '&' => .ampersand,
            '?' => .question,
            '[' => .l_bracket,
            ']' => .r_bracket,
            '<' => .lt,
            '>' => .gt,
            else => null,
        };

        if (punct) |kind| {
            try out.append(arena, .{ .kind = kind, .span = .{ .start = i, .end = i + 1 } });
            i += 1;
            continue;
        }

        const width: u32 = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const end: u32 = @intCast(@min(text.len, i + width));
        const span: Span = .{ .start = i, .end = end };
        try diags.err(.unexpected_char, span, "unexpected character", "not valid in Relastic source", null);
        try out.append(arena, .{ .kind = .invalid, .span = span });
        i = end;
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
    if (std.mem.eql(u8, name, "mut")) return .kw_mut;
    if (std.mem.eql(u8, name, "struct")) return .kw_struct;
    if (std.mem.eql(u8, name, "enum")) return .kw_enum;
    if (std.mem.eql(u8, name, "match")) return .kw_match;
    if (std.mem.eql(u8, name, "if")) return .kw_if;
    if (std.mem.eql(u8, name, "else")) return .kw_else;
    if (std.mem.eql(u8, name, "while")) return .kw_while;
    if (std.mem.eql(u8, name, "true")) return .kw_true;
    if (std.mem.eql(u8, name, "false")) return .kw_false;
    if (std.mem.eql(u8, name, "and")) return .kw_and;
    if (std.mem.eql(u8, name, "or")) return .kw_or;
    if (std.mem.eql(u8, name, "not")) return .kw_not;
    if (std.mem.eql(u8, name, "return")) return .kw_return;
    if (std.mem.eql(u8, name, "trait")) return .kw_trait;
    if (std.mem.eql(u8, name, "impl")) return .kw_impl;
    if (std.mem.eql(u8, name, "for")) return .kw_for;
    if (std.mem.eql(u8, name, "self")) return .kw_self;
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
