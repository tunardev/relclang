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
const parseBlock = @import("stmt.zig").parseBlock;
const peek = @import("core.zig").peek;
const recoverInBlock = @import("core.zig").recoverInBlock;
const skipNewlines = @import("core.zig").skipNewlines;
const startsUpper = @import("core.zig").startsUpper;

pub fn parseExpr(p: *Parser) Error!?ast.Expr {
    return parseBinary(p, 1);
}

pub fn parseBinary(p: *Parser, min_level: u8) Error!?ast.Expr {
    var lhs = try parseUnary(p) orelse return null;

    while (precedenceOf(peek(p))) |info| {
        if (info.level < min_level) break;
        const op_tok = advance(p);
        const rhs = try parseBinary(p, info.level + 1) orelse return null;

        const lhs_ptr = try p.arena.create(ast.Expr);
        lhs_ptr.* = lhs;
        const rhs_ptr = try p.arena.create(ast.Expr);
        rhs_ptr.* = rhs;

        const merged = Span.merge(lhs.spanOf(), rhs.spanOf());

        lhs = .{ .binary = .{
            .op = info.op,
            .lhs = lhs_ptr,
            .rhs = rhs_ptr,
            .op_span = op_tok.span,
            .span = merged,
        } };
    }

    return lhs;
}

pub fn parseUnary(p: *Parser) Error!?ast.Expr {
    if (peek(p) == .ampersand) {
        const amp = advance(p);
        var mutable = false;
        if (peek(p) == .kw_mut) {
            _ = advance(p);
            mutable = true;
        }
        const operand = try parseUnary(p) orelse return null;
        const ptr = try p.arena.create(ast.Expr);
        ptr.* = operand;
        return .{ .borrow = .{
            .mutable = mutable,
            .operand = ptr,
            .span = Span.merge(amp.span, operand.spanOf()),
        } };
    }

    const op: ast.UnOp = switch (peek(p)) {
        .minus => .neg,
        .kw_not => .not,
        else => return parsePostfix(p),
    };

    const op_tok = advance(p);
    const operand = try parseUnary(p) orelse return null;

    const ptr = try p.arena.create(ast.Expr);
    ptr.* = operand;
    const merged = Span.merge(op_tok.span, operand.spanOf());

    return .{ .unary = .{
        .op = op,
        .operand = ptr,
        .op_span = op_tok.span,
        .span = merged,
    } };
}

pub fn parsePostfix(p: *Parser) Error!?ast.Expr {
    var expr = try parsePrimary(p) orelse return null;

    while (true) {
        switch (peek(p)) {
            .dot => {
                _ = advance(p);
                const field = try expect(p, .ident, "expected a field name", null) orelse return null;

                if (peek(p) == .l_paren) {
                    _ = advance(p);
                    var args: std.ArrayList(ast.Expr) = .empty;
                    if (peek(p) != .r_paren) {
                        while (true) {
                            const arg = try parseExpr(p) orelse return null;
                            try args.append(p.arena, arg);
                            if (peek(p) != .comma) break;
                            _ = advance(p);
                        }
                    }
                    const close = try expect(p, .r_paren, "expected `)`", "close the method call") orelse return null;

                    const recv = try p.arena.create(ast.Expr);
                    recv.* = expr;
                    const call_span = Span.merge(expr.spanOf(), close.span);

                    expr = .{ .method_call = .{
                        .receiver = recv,
                        .name = field.value,
                        .name_span = field.span,
                        .args = try args.toOwnedSlice(p.arena),
                        .span = call_span,
                    } };
                    continue;
                }

                const base = try p.arena.create(ast.Expr);
                base.* = expr;
                const merged = Span.merge(expr.spanOf(), field.span);

                expr = .{ .field = .{
                    .base = base,
                    .field = field.value,
                    .field_span = field.span,
                    .span = merged,
                } };
            },
            .question => {
                const q = advance(p);
                const inner = try p.arena.create(ast.Expr);
                inner.* = expr;
                const merged = Span.merge(expr.spanOf(), q.span);
                expr = .{ .try_expr = .{ .operand = inner, .span = merged } };
            },
            .l_bracket => {
                _ = advance(p);
                const idx = try parseExpr(p) orelse return null;
                const close = try expect(p, .r_bracket, "expected `]`", "add `]` to close the index") orelse return null;

                const base = try p.arena.create(ast.Expr);
                base.* = expr;
                const idx_ptr = try p.arena.create(ast.Expr);
                idx_ptr.* = idx;
                const merged = Span.merge(expr.spanOf(), close.span);

                expr = .{ .index = .{
                    .base = base,
                    .index = idx_ptr,
                    .span = merged,
                } };
            },
            else => return expr,
        }
    }
}

pub fn parsePrimary(p: *Parser) Error!?ast.Expr {
    switch (peek(p)) {
        .kw_match => return try parseMatch(p),
        .kw_if => return try parseIf(p),
        .kw_while => return try parseWhile(p),
        .kw_self => {
            const t = advance(p);
            return .{ .var_ref = .{ .name = "self", .span = t.span } };
        },
        .kw_true, .kw_false => {
            const t = advance(p);
            return .{ .boolean = .{ .value = t.kind == .kw_true, .span = t.span } };
        },
        .l_bracket => {
            const open = advance(p);
            var elems: std.ArrayList(ast.Expr) = .empty;

            skipNewlines(p);
            if (peek(p) != .r_bracket) {
                while (true) {
                    skipNewlines(p);
                    const e = try parseExpr(p) orelse return null;
                    try elems.append(p.arena, e);
                    skipNewlines(p);
                    if (peek(p) != .comma) break;
                    _ = advance(p);
                    skipNewlines(p);
                    if (peek(p) == .r_bracket) break;
                }
            }

            skipNewlines(p);
            const close = try expect(p, .r_bracket, "expected `]`", "add `]` to close the array") orelse return null;

            return .{ .array_lit = .{
                .elems = try elems.toOwnedSlice(p.arena),
                .span = Span.merge(open.span, close.span),
            } };
        },
        .string => {
            const t = advance(p);
            return .{ .string = .{ .value = t.value, .span = t.span } };
        },
        .int => {
            const t = advance(p);
            return .{ .int = .{ .text = t.value, .span = t.span } };
        },
        .l_paren => {
            _ = advance(p);
            const inner = try parseExpr(p) orelse return null;
            _ = try expect(p, .r_paren, "expected `)`", "add `)` to close the group") orelse return null;
            return inner;
        },
        .ident => {
            if (p.tokens[p.pos + 1].kind == .l_paren) return try parseCall(p);
            if (!p.no_struct_lit and p.tokens[p.pos + 1].kind == .l_brace and startsUpper(current(p).value)) {
                return try parseStructLit(p);
            }
            const t = advance(p);
            return .{ .var_ref = .{ .name = t.value, .span = t.span } };
        },
        else => {
            try p.diags.err(
                .unexpected_token,
                current(p).span,
                "expected an expression",
                "expected a value, a variable, or a function call",
                null,
            );
            return null;
        },
    }
}

pub fn parseCall(p: *Parser) Error!?ast.Expr {
    const name = advance(p);
    _ = try expect(p, .l_paren, "expected `(` to start a call", null) orelse return null;

    var args: std.ArrayList(ast.Expr) = .empty;

    if (peek(p) != .r_paren) {
        while (true) {
            const arg = try parseExpr(p) orelse return null;
            try args.append(p.arena, arg);
            if (peek(p) != .comma) break;
            _ = advance(p);
        }
    }

    const close = try expect(p, .r_paren, "expected `)`", "add `)` to close the call") orelse return null;

    return .{ .call = .{
        .callee = name.value,
        .callee_span = name.span,
        .args = try args.toOwnedSlice(p.arena),
        .span = Span.merge(name.span, close.span),
    } };
}

pub fn parseStructLit(p: *Parser) Error!?ast.Expr {
    const name = advance(p);
    _ = advance(p);

    var fields: std.ArrayList(ast.FieldInit) = .empty;

    while (true) {
        skipNewlines(p);
        if (peek(p) == .r_brace or peek(p) == .eof) break;

        const fname = try expect(p, .ident, "expected a field name", null) orelse return null;
        _ = try expect(p, .colon, "expected `:`", "a field looks like `name: value`") orelse return null;
        const value = try parseExpr(p) orelse return null;

        try fields.append(p.arena, .{ .name = fname.value, .name_span = fname.span, .value = value });

        skipNewlines(p);
        if (peek(p) != .comma) break;
        _ = advance(p);
    }

    skipNewlines(p);
    const close = try expect(p, .r_brace, "expected `}`", "add `}` to close the struct literal") orelse return null;

    return .{ .struct_lit = .{
        .name = name.value,
        .name_span = name.span,
        .fields = try fields.toOwnedSlice(p.arena),
        .span = Span.merge(name.span, close.span),
    } };
}

pub fn parseCondition(p: *Parser) Error!?ast.Expr {
    const saved = p.no_struct_lit;
    p.no_struct_lit = true;
    defer p.no_struct_lit = saved;
    return parseExpr(p);
}

pub fn precedenceOf(kind: Kind) ?struct { op: ast.BinOp, level: u8 } {
    return switch (kind) {
        .kw_or => .{ .op = .logical_or, .level = 1 },
        .kw_and => .{ .op = .logical_and, .level = 2 },
        .eq_eq => .{ .op = .eq, .level = 3 },
        .bang_eq => .{ .op = .ne, .level = 3 },
        .lt => .{ .op = .lt, .level = 3 },
        .gt => .{ .op = .gt, .level = 3 },
        .le => .{ .op = .le, .level = 3 },
        .ge => .{ .op = .ge, .level = 3 },
        .plus => .{ .op = .add, .level = 4 },
        .minus => .{ .op = .sub, .level = 4 },
        .star => .{ .op = .mul, .level = 5 },
        .slash => .{ .op = .div, .level = 5 },
        .percent => .{ .op = .rem, .level = 5 },
        else => null,
    };
}

pub fn parseIf(p: *Parser) Error!?ast.Expr {
    const kw = advance(p);

    const cond = try parseCondition(p) orelse return null;
    skipNewlines(p);

    const then_block = try parseBlock(p) orelse return null;

    var else_block: ?ast.Block = null;
    var else_if: ?*const ast.Expr = null;
    var end = then_block.span;

    const save = p.pos;
    skipNewlines(p);

    if (peek(p) == .kw_else) {
        _ = advance(p);
        skipNewlines(p);

        if (peek(p) == .kw_if) {
            const nested = try parseIf(p) orelse return null;
            const ptr = try p.arena.create(ast.Expr);
            ptr.* = nested;
            else_if = ptr;
            end = nested.spanOf();
        } else {
            const b = try parseBlock(p) orelse return null;
            else_block = b;
            end = b.span;
        }
    } else {
        p.pos = save;
    }

    const cond_ptr = try p.arena.create(ast.Expr);
    cond_ptr.* = cond;

    return .{ .if_expr = .{
        .cond = cond_ptr,
        .then_block = then_block,
        .else_block = else_block,
        .else_if = else_if,
        .span = Span.merge(kw.span, end),
    } };
}

pub fn parseWhile(p: *Parser) Error!?ast.Expr {
    const kw = advance(p);

    const cond = try parseCondition(p) orelse return null;
    skipNewlines(p);

    const body = try parseBlock(p) orelse return null;

    const cond_ptr = try p.arena.create(ast.Expr);
    cond_ptr.* = cond;

    return .{ .while_expr = .{
        .cond = cond_ptr,
        .body = body,
        .span = Span.merge(kw.span, body.span),
    } };
}

pub fn parseMatch(p: *Parser) Error!?ast.Expr {
    const kw = advance(p);

    const scrutinee = try parseCondition(p) orelse return null;

    skipNewlines(p);
    _ = try expect(p, .l_brace, "expected `{`", "a match needs a block of arms") orelse return null;

    var arms: std.ArrayList(ast.Arm) = .empty;

    while (true) {
        skipNewlines(p);
        if (peek(p) == .r_brace or peek(p) == .eof) break;

        const before = p.pos;

        const pattern = try parsePattern(p) orelse {
            recoverInBlock(p);
            if (p.pos == before) p.pos += 1;
            continue;
        };

        _ = try expect(p, .fat_arrow, "expected `=>`", "an arm looks like `Pattern => value`") orelse {
            recoverInBlock(p);
            if (p.pos == before) p.pos += 1;
            continue;
        };

        const body = try parseExpr(p) orelse {
            recoverInBlock(p);
            if (p.pos == before) p.pos += 1;
            continue;
        };

        try arms.append(p.arena, .{
            .pattern = pattern,
            .body = body,
            .span = Span.merge(pattern.spanOf(), body.spanOf()),
        });

        if (peek(p) == .comma) _ = advance(p);
        if (p.pos == before) p.pos += 1;
    }

    const close = try expect(p, .r_brace, "expected `}`", "the match is never closed") orelse current(p);

    const scrut_ptr = try p.arena.create(ast.Expr);
    scrut_ptr.* = scrutinee;

    return .{ .match = .{
        .scrutinee = scrut_ptr,
        .arms = try arms.toOwnedSlice(p.arena),
        .span = Span.merge(kw.span, close.span),
    } };
}

pub fn parsePattern(p: *Parser) Error!?ast.Pattern {
    const name_tok = try expect(p, .ident, "expected a pattern", "a pattern is a variant name or `_`") orelse return null;

    if (std.mem.eql(u8, name_tok.value, "_")) return .{ .wildcard = name_tok.span };

    var bindings: std.ArrayList(ast.Binding) = .empty;
    var has_parens = false;
    var end = name_tok.span;

    if (peek(p) == .l_paren) {
        has_parens = true;
        _ = advance(p);
        if (peek(p) != .r_paren) {
            while (true) {
                const b = try expect(p, .ident, "expected a binding name", null) orelse return null;
                try bindings.append(p.arena, .{ .name = b.value, .span = b.span });
                if (peek(p) != .comma) break;
                _ = advance(p);
            }
        }
        const close = try expect(p, .r_paren, "expected `)`", null) orelse return null;
        end = close.span;
    }

    return .{ .variant = .{
        .name = name_tok.value,
        .name_span = name_tok.span,
        .bindings = try bindings.toOwnedSlice(p.arena),
        .has_parens = has_parens,
        .span = Span.merge(name_tok.span, end),
    } };
}
