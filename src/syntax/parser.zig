const std = @import("std");
const source = @import("../support/source.zig");
const diagnostics = @import("../support/diagnostics.zig");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

const core = @import("parse/core.zig");
const item = @import("parse/item.zig");

const Token = token.Token;
const Span = source.Span;

pub const Parser = core.Parser;

pub fn parse(
    arena: std.mem.Allocator,
    tokens: []const Token,
    diags: *diagnostics.Diagnostics,
) !ast.Program {
    var p: Parser = .{ .arena = arena, .tokens = tokens, .diags = diags, .pos = 0 };
    return item.parseProgram(&p);
}
