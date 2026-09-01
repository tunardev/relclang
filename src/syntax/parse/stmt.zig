const std = @import("std");
const source = @import("../../support/source.zig");
const diagnostics = @import("../../support/diagnostics.zig");
const token = @import("../token.zig");
const ast = @import("../ast.zig");

const Token = token.Token;
const Kind = token.Kind;
const Span = source.Span;
const core = @import("core.zig");

const Parser = core.Parser;
const Error = core.Error;
const advance = @import("core.zig").advance;
const current = @import("core.zig").current;
const expect = @import("core.zig").expect;
const parseExpr = @import("expr.zig").parseExpr;
const parseType = @import("type.zig").parseType;
const peek = @import("core.zig").peek;
const recoverInBlock = @import("core.zig").recoverInBlock;
const skipNewlines = @import("core.zig").skipNewlines;

pub fn parseStmt(p: *Parser) Error!?ast.Stmt {
    if (peek(p) == .kw_return) {
        const kw = advance(p);
        var value: ?ast.Expr = null;
        var end = kw.span;

        if (peek(p) != .newline and peek(p) != .r_brace and peek(p) != .eof) {
            const e = try parseExpr(p) orelse return null;
            value = e;
            end = e.spanOf();
        }

        return .{ .ret = .{ .value = value, .span = Span.merge(kw.span, end) } };
    }

    if (peek(p) != .kw_let) {
        const e = try parseExpr(p) orelse return null;

        if (peek(p) == .equals) {
            _ = advance(p);
            const value = try parseExpr(p) orelse return null;
            return .{ .assign = .{
                .target = e,
                .value = value,
                .span = Span.merge(e.spanOf(), value.spanOf()),
            } };
        }

        return .{ .expr = e };
    }

    const kw = advance(p);

    var is_mut = false;
    if (peek(p) == .kw_mut) {
        _ = advance(p);
        is_mut = true;
    }

    const name_tok = try expect(p, .ident, "expected a variable name", null) orelse return null;

    var ty: ?ast.TypeExpr = null;
    if (peek(p) == .colon) {
        _ = advance(p);
        ty = try parseType(p) orelse return null;
    }

    _ = try expect(p, .equals, "expected `=`", "a `let` binding needs an initial value") orelse return null;

    const init_expr = try parseExpr(p) orelse return null;

    return .{ .let = .{
        .name = name_tok.value,
        .name_span = name_tok.span,
        .is_mut = is_mut,
        .ty = ty,
        .init = init_expr,
        .span = Span.merge(kw.span, init_expr.spanOf()),
    } };
}

pub fn parseBlock(p: *Parser) Error!?ast.Block {
    const open = try expect(p, .l_brace, "expected `{`", null) orelse return null;

    var stmts: std.ArrayList(ast.Stmt) = .empty;

    while (true) {
        skipNewlines(p);
        if (peek(p) == .r_brace or peek(p) == .eof) break;

        const before = p.pos;

        const saved_no_struct = p.no_struct_lit;
        p.no_struct_lit = false;
        const parsed_stmt = try parseStmt(p);
        p.no_struct_lit = saved_no_struct;

        if (parsed_stmt) |stmt| {
            try stmts.append(p.arena, stmt);
            if (peek(p) != .r_brace and peek(p) != .eof and peek(p) != .newline) {
                try p.diags.err(
                    .unexpected_token,
                    current(p).span,
                    "unexpected token after statement",
                    "expected a line break here",
                    null,
                );
                recoverInBlock(p);
            }
        } else {
            recoverInBlock(p);
        }

        if (p.pos == before) p.pos += 1;
    }

    const close = try expect(p, .r_brace, "expected `}`", "the function body is never closed") orelse
        current(p);

    return .{
        .stmts = try stmts.toOwnedSlice(p.arena),
        .span = Span.merge(open.span, close.span),
    };
}
