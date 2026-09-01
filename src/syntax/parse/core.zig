const std = @import("std");
const source = @import("../../support/source.zig");
const diagnostics = @import("../../support/diagnostics.zig");
const token = @import("../token.zig");
const ast = @import("../ast.zig");

const Token = token.Token;
const Kind = token.Kind;
const Span = source.Span;

pub const Error = error{OutOfMemory};

pub const Parser = struct {
    arena: std.mem.Allocator,
    tokens: []const Token,
    diags: *diagnostics.Diagnostics,
    pos: usize,
    no_struct_lit: bool = false,
};

pub fn peek(p: *Parser) Kind {
    return p.tokens[p.pos].kind;
}

pub fn current(p: *Parser) Token {
    return p.tokens[p.pos];
}

pub fn advance(p: *Parser) Token {
    const t = p.tokens[p.pos];
    if (t.kind != .eof) p.pos += 1;
    return t;
}

pub fn skipNewlines(p: *Parser) void {
    while (peek(p) == .newline) p.pos += 1;
}

pub fn expect(p: *Parser, kind: Kind, label: []const u8, help: ?[]const u8) Error!?Token {
    if (peek(p) == kind) return advance(p);
    try p.diags.err(.unexpected_token, current(p).span, "unexpected token", label, help);
    return null;
}

pub fn recoverToTopLevel(p: *Parser) void {
    while (peek(p) != .eof and
        peek(p) != .kw_fn and
        peek(p) != .kw_struct and
        peek(p) != .kw_enum and
        peek(p) != .kw_trait and
        peek(p) != .kw_impl) p.pos += 1;
}

pub fn recoverInBlock(p: *Parser) void {
    while (peek(p) != .newline and peek(p) != .r_brace and peek(p) != .eof) p.pos += 1;
}

pub fn startsUpper(name: []const u8) bool {
    return name.len > 0 and name[0] >= 'A' and name[0] <= 'Z';
}
