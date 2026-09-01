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
const expect = @import("core.zig").expect;
const peek = @import("core.zig").peek;

pub fn parseType(p: *Parser) Error!?ast.TypeExpr {
    if (peek(p) == .ampersand) {
        const amp = advance(p);
        var mutable = false;
        if (peek(p) == .kw_mut) {
            _ = advance(p);
            mutable = true;
        }
        const target = try parseType(p) orelse return null;
        const ptr = try p.arena.create(ast.TypeExpr);
        ptr.* = target;
        return .{ .ref = .{
            .mutable = mutable,
            .target = ptr,
            .span = Span.merge(amp.span, target.spanOf()),
        } };
    }

    if (peek(p) == .l_bracket) {
        const open = advance(p);
        const elem = try parseType(p) orelse return null;
        _ = try expect(p, .semicolon, "expected `;`", "an array type looks like `[Int; 3]`") orelse return null;
        const len_tok = try expect(p, .int, "expected an array length", null) orelse return null;
        const close = try expect(p, .r_bracket, "expected `]`", null) orelse return null;

        const elem_ptr = try p.arena.create(ast.TypeExpr);
        elem_ptr.* = elem;

        return .{ .array = .{
            .elem = elem_ptr,
            .len_text = len_tok.value,
            .len_span = len_tok.span,
            .span = Span.merge(open.span, close.span),
        } };
    }

    const t = try expect(p, .ident, "expected a type name", null) orelse return null;

    var args: std.ArrayList(ast.TypeExpr) = .empty;
    var end = t.span;

    if (peek(p) == .lt) {
        _ = advance(p);
        while (true) {
            const arg = try parseType(p) orelse return null;
            try args.append(p.arena, arg);
            if (peek(p) != .comma) break;
            _ = advance(p);
        }
        const close = try expect(p, .gt, "expected `>`", "close the type arguments") orelse return null;
        end = close.span;
    }

    return .{ .named = .{
        .name = t.value,
        .args = try args.toOwnedSlice(p.arena),
        .span = Span.merge(t.span, end),
    } };
}
