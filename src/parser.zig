const std = @import("std");
const source = @import("source.zig");
const diagnostics = @import("diagnostics.zig");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

const Token = token.Token;
const Kind = token.Kind;
const Span = source.Span;

const Error = error{OutOfMemory};

const Parser = struct {
    arena: std.mem.Allocator,
    tokens: []const Token,
    diags: *diagnostics.Diagnostics,
    pos: usize,
    no_struct_lit: bool = false,

    fn peek(p: *Parser) Kind {
        return p.tokens[p.pos].kind;
    }

    fn current(p: *Parser) Token {
        return p.tokens[p.pos];
    }

    fn advance(p: *Parser) Token {
        const t = p.tokens[p.pos];
        if (t.kind != .eof) p.pos += 1;
        return t;
    }

    fn skipNewlines(p: *Parser) void {
        while (p.peek() == .newline) p.pos += 1;
    }

    fn expect(p: *Parser, kind: Kind, label: []const u8, help: ?[]const u8) Error!?Token {
        if (p.peek() == kind) return p.advance();
        try p.diags.err(.unexpected_token, p.current().span, "unexpected token", label, help);
        return null;
    }

    fn parseProgram(p: *Parser) Error!ast.Program {
        var fns: std.ArrayList(ast.Fn) = .empty;
        var structs: std.ArrayList(ast.StructDecl) = .empty;
        var enums: std.ArrayList(ast.EnumDecl) = .empty;

        while (true) {
            p.skipNewlines();
            if (p.peek() == .eof) break;

            switch (p.peek()) {
                .kw_fn => if (try p.parseFn()) |f| try fns.append(p.arena, f),
                .kw_struct => if (try p.parseStruct()) |d| try structs.append(p.arena, d),
                .kw_enum => if (try p.parseEnum()) |d| try enums.append(p.arena, d),
                else => {
                    try p.diags.err(
                        .unexpected_token,
                        p.current().span,
                        "expected a top level definition",
                        "only `fn`, `struct` and `enum` are allowed here",
                        null,
                    );
                    p.recoverToTopLevel();
                },
            }
        }

        return .{
            .fns = try fns.toOwnedSlice(p.arena),
            .structs = try structs.toOwnedSlice(p.arena),
            .enums = try enums.toOwnedSlice(p.arena),
        };
    }

    fn recoverToTopLevel(p: *Parser) void {
        while (p.peek() != .eof and p.peek() != .kw_fn and p.peek() != .kw_struct and p.peek() != .kw_enum) p.pos += 1;
    }

    fn parseStruct(p: *Parser) Error!?ast.StructDecl {
        const kw = p.advance();

        const name_tok = try p.expect(.ident, "expected a struct name", null) orelse {
            p.recoverToTopLevel();
            return null;
        };

        const type_params = try p.parseTypeParams() orelse {
            p.recoverToTopLevel();
            return null;
        };

        p.skipNewlines();
        _ = try p.expect(.l_brace, "expected `{`", null) orelse {
            p.recoverToTopLevel();
            return null;
        };

        var fields: std.ArrayList(ast.FieldDecl) = .empty;

        while (true) {
            p.skipNewlines();
            if (p.peek() == .r_brace or p.peek() == .eof) break;

            const before = p.pos;

            const fname = try p.expect(.ident, "expected a field name", null) orelse {
                p.recoverInBlock();
                if (p.pos == before) p.pos += 1;
                continue;
            };
            _ = try p.expect(.colon, "expected `:`", "every field needs a type") orelse {
                p.recoverInBlock();
                if (p.pos == before) p.pos += 1;
                continue;
            };
            const fty = try p.parseType() orelse {
                p.recoverInBlock();
                if (p.pos == before) p.pos += 1;
                continue;
            };

            try fields.append(p.arena, .{ .name = fname.value, .name_span = fname.span, .ty = fty });

            if (p.peek() == .comma) _ = p.advance();
            if (p.pos == before) p.pos += 1;
        }

        const close = try p.expect(.r_brace, "expected `}`", "the struct body is never closed") orelse p.current();

        return .{
            .name = name_tok.value,
            .name_span = name_tok.span,
            .type_params = type_params,
            .fields = try fields.toOwnedSlice(p.arena),
            .span = Span.merge(kw.span, close.span),
        };
    }

    fn parseEnum(p: *Parser) Error!?ast.EnumDecl {
        const kw = p.advance();

        const name_tok = try p.expect(.ident, "expected an enum name", null) orelse {
            p.recoverToTopLevel();
            return null;
        };

        const type_params = try p.parseTypeParams() orelse {
            p.recoverToTopLevel();
            return null;
        };

        p.skipNewlines();
        _ = try p.expect(.l_brace, "expected `{`", null) orelse {
            p.recoverToTopLevel();
            return null;
        };

        var variants: std.ArrayList(ast.VariantDecl) = .empty;

        while (true) {
            p.skipNewlines();
            if (p.peek() == .r_brace or p.peek() == .eof) break;

            const before = p.pos;

            const vname = try p.expect(.ident, "expected a variant name", null) orelse {
                p.recoverInBlock();
                if (p.pos == before) p.pos += 1;
                continue;
            };

            var payload: std.ArrayList(ast.TypeExpr) = .empty;
            if (p.peek() == .l_paren) {
                _ = p.advance();
                if (p.peek() != .r_paren) {
                    while (true) {
                        const ty = try p.parseType() orelse break;
                        try payload.append(p.arena, ty);
                        if (p.peek() != .comma) break;
                        _ = p.advance();
                    }
                }
                _ = try p.expect(.r_paren, "expected `)`", null) orelse {
                    p.recoverInBlock();
                    if (p.pos == before) p.pos += 1;
                    continue;
                };
            }

            try variants.append(p.arena, .{
                .name = vname.value,
                .name_span = vname.span,
                .payload = try payload.toOwnedSlice(p.arena),
            });

            if (p.peek() == .comma) _ = p.advance();
            if (p.pos == before) p.pos += 1;
        }

        const close = try p.expect(.r_brace, "expected `}`", "the enum body is never closed") orelse p.current();

        return .{
            .name = name_tok.value,
            .name_span = name_tok.span,
            .type_params = type_params,
            .variants = try variants.toOwnedSlice(p.arena),
            .span = Span.merge(kw.span, close.span),
        };
    }

    fn parsePattern(p: *Parser) Error!?ast.Pattern {
        const name_tok = try p.expect(.ident, "expected a pattern", "a pattern is a variant name or `_`") orelse return null;

        if (std.mem.eql(u8, name_tok.value, "_")) return .{ .wildcard = name_tok.span };

        var bindings: std.ArrayList(ast.Binding) = .empty;
        var has_parens = false;
        var end = name_tok.span;

        if (p.peek() == .l_paren) {
            has_parens = true;
            _ = p.advance();
            if (p.peek() != .r_paren) {
                while (true) {
                    const b = try p.expect(.ident, "expected a binding name", null) orelse return null;
                    try bindings.append(p.arena, .{ .name = b.value, .span = b.span });
                    if (p.peek() != .comma) break;
                    _ = p.advance();
                }
            }
            const close = try p.expect(.r_paren, "expected `)`", null) orelse return null;
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

    fn parseMatch(p: *Parser) Error!?ast.Expr {
        const kw = p.advance();

        const scrutinee = try p.parseCondition() orelse return null;

        p.skipNewlines();
        _ = try p.expect(.l_brace, "expected `{`", "a match needs a block of arms") orelse return null;

        var arms: std.ArrayList(ast.Arm) = .empty;

        while (true) {
            p.skipNewlines();
            if (p.peek() == .r_brace or p.peek() == .eof) break;

            const before = p.pos;

            const pattern = try p.parsePattern() orelse {
                p.recoverInBlock();
                if (p.pos == before) p.pos += 1;
                continue;
            };

            _ = try p.expect(.fat_arrow, "expected `=>`", "an arm looks like `Pattern => value`") orelse {
                p.recoverInBlock();
                if (p.pos == before) p.pos += 1;
                continue;
            };

            const body = try p.parseExpr() orelse {
                p.recoverInBlock();
                if (p.pos == before) p.pos += 1;
                continue;
            };

            try arms.append(p.arena, .{
                .pattern = pattern,
                .body = body,
                .span = Span.merge(pattern.spanOf(), body.spanOf()),
            });

            if (p.peek() == .comma) _ = p.advance();
            if (p.pos == before) p.pos += 1;
        }

        const close = try p.expect(.r_brace, "expected `}`", "the match is never closed") orelse p.current();

        const scrut_ptr = try p.arena.create(ast.Expr);
        scrut_ptr.* = scrutinee;

        return .{ .match = .{
            .scrutinee = scrut_ptr,
            .arms = try arms.toOwnedSlice(p.arena),
            .span = Span.merge(kw.span, close.span),
        } };
    }

    fn parseType(p: *Parser) Error!?ast.TypeExpr {
        if (p.peek() == .ampersand) {
            const amp = p.advance();
            var mutable = false;
            if (p.peek() == .kw_mut) {
                _ = p.advance();
                mutable = true;
            }
            const target = try p.parseType() orelse return null;
            const ptr = try p.arena.create(ast.TypeExpr);
            ptr.* = target;
            return .{ .ref = .{
                .mutable = mutable,
                .target = ptr,
                .span = Span.merge(amp.span, target.spanOf()),
            } };
        }

        if (p.peek() == .l_bracket) {
            const open = p.advance();
            const elem = try p.parseType() orelse return null;
            _ = try p.expect(.semicolon, "expected `;`", "an array type looks like `[Int; 3]`") orelse return null;
            const len_tok = try p.expect(.int, "expected an array length", null) orelse return null;
            const close = try p.expect(.r_bracket, "expected `]`", null) orelse return null;

            const elem_ptr = try p.arena.create(ast.TypeExpr);
            elem_ptr.* = elem;

            return .{ .array = .{
                .elem = elem_ptr,
                .len_text = len_tok.value,
                .len_span = len_tok.span,
                .span = Span.merge(open.span, close.span),
            } };
        }

        const t = try p.expect(.ident, "expected a type name", null) orelse return null;

        var args: std.ArrayList(ast.TypeExpr) = .empty;
        var end = t.span;

        if (p.peek() == .lt) {
            _ = p.advance();
            while (true) {
                const arg = try p.parseType() orelse return null;
                try args.append(p.arena, arg);
                if (p.peek() != .comma) break;
                _ = p.advance();
            }
            const close = try p.expect(.gt, "expected `>`", "close the type arguments") orelse return null;
            end = close.span;
        }

        return .{ .named = .{
            .name = t.value,
            .args = try args.toOwnedSlice(p.arena),
            .span = Span.merge(t.span, end),
        } };
    }

    fn parseTypeParams(p: *Parser) Error!?[]const ast.TypeParam {
        var list: std.ArrayList(ast.TypeParam) = .empty;

        if (p.peek() != .lt) return try list.toOwnedSlice(p.arena);

        _ = p.advance();
        while (true) {
            const name = try p.expect(.ident, "expected a type parameter name", null) orelse return null;
            try list.append(p.arena, .{ .name = name.value, .span = name.span });
            if (p.peek() != .comma) break;
            _ = p.advance();
        }
        _ = try p.expect(.gt, "expected `>`", "close the type parameters") orelse return null;

        return try list.toOwnedSlice(p.arena);
    }

    fn parseFn(p: *Parser) Error!?ast.Fn {
        const kw = p.advance();

        const name_tok = try p.expect(.ident, "expected a function name", null) orelse {
            p.recoverToTopLevel();
            return null;
        };

        const type_params = try p.parseTypeParams() orelse {
            p.recoverToTopLevel();
            return null;
        };

        _ = try p.expect(.l_paren, "expected `(`", null) orelse {
            p.recoverToTopLevel();
            return null;
        };

        var params: std.ArrayList(ast.Param) = .empty;
        if (p.peek() != .r_paren) {
            while (true) {
                const pname = try p.expect(.ident, "expected a parameter name", null) orelse {
                    p.recoverToTopLevel();
                    return null;
                };
                _ = try p.expect(.colon, "expected `:`", "every parameter needs a type") orelse {
                    p.recoverToTopLevel();
                    return null;
                };
                const pty = try p.parseType() orelse {
                    p.recoverToTopLevel();
                    return null;
                };
                try params.append(p.arena, .{
                    .name = pname.value,
                    .name_span = pname.span,
                    .ty = pty,
                });
                if (p.peek() != .comma) break;
                _ = p.advance();
            }
        }

        _ = try p.expect(.r_paren, "expected `)`", null) orelse {
            p.recoverToTopLevel();
            return null;
        };

        var ret_ty: ?ast.TypeExpr = null;
        if (p.peek() == .arrow) {
            _ = p.advance();
            ret_ty = try p.parseType() orelse {
                p.recoverToTopLevel();
                return null;
            };
        }

        p.skipNewlines();

        const body = try p.parseBlock() orelse {
            p.recoverToTopLevel();
            return null;
        };

        return .{
            .name = name_tok.value,
            .name_span = name_tok.span,
            .type_params = type_params,
            .params = try params.toOwnedSlice(p.arena),
            .ret_ty = ret_ty,
            .body = body,
            .span = Span.merge(kw.span, body.span),
        };
    }

    fn parseBlock(p: *Parser) Error!?ast.Block {
        const open = try p.expect(.l_brace, "expected `{`", null) orelse return null;

        var stmts: std.ArrayList(ast.Stmt) = .empty;

        while (true) {
            p.skipNewlines();
            if (p.peek() == .r_brace or p.peek() == .eof) break;

            const before = p.pos;

            const saved_no_struct = p.no_struct_lit;
            p.no_struct_lit = false;
            const parsed_stmt = try p.parseStmt();
            p.no_struct_lit = saved_no_struct;

            if (parsed_stmt) |stmt| {
                try stmts.append(p.arena, stmt);
                if (p.peek() != .r_brace and p.peek() != .eof and p.peek() != .newline) {
                    try p.diags.err(
                        .unexpected_token,
                        p.current().span,
                        "unexpected token after statement",
                        "expected a line break here",
                        null,
                    );
                    p.recoverInBlock();
                }
            } else {
                p.recoverInBlock();
            }

            if (p.pos == before) p.pos += 1;
        }

        const close = try p.expect(.r_brace, "expected `}`", "the function body is never closed") orelse
            p.current();

        return .{
            .stmts = try stmts.toOwnedSlice(p.arena),
            .span = Span.merge(open.span, close.span),
        };
    }

    fn recoverInBlock(p: *Parser) void {
        while (p.peek() != .newline and p.peek() != .r_brace and p.peek() != .eof) p.pos += 1;
    }

    fn parseStmt(p: *Parser) Error!?ast.Stmt {
        if (p.peek() != .kw_let) {
            const e = try p.parseExpr() orelse return null;

            if (p.peek() == .equals) {
                _ = p.advance();
                const value = try p.parseExpr() orelse return null;
                return .{ .assign = .{
                    .target = e,
                    .value = value,
                    .span = Span.merge(e.spanOf(), value.spanOf()),
                } };
            }

            return .{ .expr = e };
        }

        const kw = p.advance();

        var is_mut = false;
        if (p.peek() == .kw_mut) {
            _ = p.advance();
            is_mut = true;
        }

        const name_tok = try p.expect(.ident, "expected a variable name", null) orelse return null;

        var ty: ?ast.TypeExpr = null;
        if (p.peek() == .colon) {
            _ = p.advance();
            ty = try p.parseType() orelse return null;
        }

        _ = try p.expect(.equals, "expected `=`", "a `let` binding needs an initial value") orelse return null;

        const init_expr = try p.parseExpr() orelse return null;

        return .{ .let = .{
            .name = name_tok.value,
            .name_span = name_tok.span,
            .is_mut = is_mut,
            .ty = ty,
            .init = init_expr,
            .span = Span.merge(kw.span, init_expr.spanOf()),
        } };
    }

    fn precedenceOf(kind: Kind) ?struct { op: ast.BinOp, level: u8 } {
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

    fn parseExpr(p: *Parser) Error!?ast.Expr {
        return p.parseBinary(1);
    }

    fn parseBinary(p: *Parser, min_level: u8) Error!?ast.Expr {
        var lhs = try p.parseUnary() orelse return null;

        while (precedenceOf(p.peek())) |info| {
            if (info.level < min_level) break;
            const op_tok = p.advance();
            const rhs = try p.parseBinary(info.level + 1) orelse return null;

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

    fn parseUnary(p: *Parser) Error!?ast.Expr {
        if (p.peek() == .ampersand) {
            const amp = p.advance();
            var mutable = false;
            if (p.peek() == .kw_mut) {
                _ = p.advance();
                mutable = true;
            }
            const operand = try p.parseUnary() orelse return null;
            const ptr = try p.arena.create(ast.Expr);
            ptr.* = operand;
            return .{ .borrow = .{
                .mutable = mutable,
                .operand = ptr,
                .span = Span.merge(amp.span, operand.spanOf()),
            } };
        }

        const op: ast.UnOp = switch (p.peek()) {
            .minus => .neg,
            .kw_not => .not,
            else => return p.parsePostfix(),
        };

        const op_tok = p.advance();
        const operand = try p.parseUnary() orelse return null;

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

    fn parseCondition(p: *Parser) Error!?ast.Expr {
        const saved = p.no_struct_lit;
        p.no_struct_lit = true;
        defer p.no_struct_lit = saved;
        return p.parseExpr();
    }

    fn parseBlock2(p: *Parser) Error!?ast.Block {
        return p.parseBlock();
    }

    fn parseIf(p: *Parser) Error!?ast.Expr {
        const kw = p.advance();

        const cond = try p.parseCondition() orelse return null;
        p.skipNewlines();

        const then_block = try p.parseBlock2() orelse return null;

        var else_block: ?ast.Block = null;
        var else_if: ?*const ast.Expr = null;
        var end = then_block.span;

        const save = p.pos;
        p.skipNewlines();

        if (p.peek() == .kw_else) {
            _ = p.advance();
            p.skipNewlines();

            if (p.peek() == .kw_if) {
                const nested = try p.parseIf() orelse return null;
                const ptr = try p.arena.create(ast.Expr);
                ptr.* = nested;
                else_if = ptr;
                end = nested.spanOf();
            } else {
                const b = try p.parseBlock2() orelse return null;
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

    fn parseWhile(p: *Parser) Error!?ast.Expr {
        const kw = p.advance();

        const cond = try p.parseCondition() orelse return null;
        p.skipNewlines();

        const body = try p.parseBlock2() orelse return null;

        const cond_ptr = try p.arena.create(ast.Expr);
        cond_ptr.* = cond;

        return .{ .while_expr = .{
            .cond = cond_ptr,
            .body = body,
            .span = Span.merge(kw.span, body.span),
        } };
    }

    fn parsePostfix(p: *Parser) Error!?ast.Expr {
        var expr = try p.parsePrimary() orelse return null;

        while (true) {
            switch (p.peek()) {
                .dot => {
                    _ = p.advance();
                    const field = try p.expect(.ident, "expected a field name", null) orelse return null;

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
                .l_bracket => {
                    _ = p.advance();
                    const idx = try p.parseExpr() orelse return null;
                    const close = try p.expect(.r_bracket, "expected `]`", "add `]` to close the index") orelse return null;

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

    fn parseStructLit(p: *Parser) Error!?ast.Expr {
        const name = p.advance();
        _ = p.advance();

        var fields: std.ArrayList(ast.FieldInit) = .empty;

        while (true) {
            p.skipNewlines();
            if (p.peek() == .r_brace or p.peek() == .eof) break;

            const fname = try p.expect(.ident, "expected a field name", null) orelse return null;
            _ = try p.expect(.colon, "expected `:`", "a field looks like `name: value`") orelse return null;
            const value = try p.parseExpr() orelse return null;

            try fields.append(p.arena, .{ .name = fname.value, .name_span = fname.span, .value = value });

            p.skipNewlines();
            if (p.peek() != .comma) break;
            _ = p.advance();
        }

        p.skipNewlines();
        const close = try p.expect(.r_brace, "expected `}`", "add `}` to close the struct literal") orelse return null;

        return .{ .struct_lit = .{
            .name = name.value,
            .name_span = name.span,
            .fields = try fields.toOwnedSlice(p.arena),
            .span = Span.merge(name.span, close.span),
        } };
    }

    fn parsePrimary(p: *Parser) Error!?ast.Expr {
        switch (p.peek()) {
            .kw_match => return try p.parseMatch(),
            .kw_if => return try p.parseIf(),
            .kw_while => return try p.parseWhile(),
            .kw_true, .kw_false => {
                const t = p.advance();
                return .{ .boolean = .{ .value = t.kind == .kw_true, .span = t.span } };
            },
            .l_bracket => {
                const open = p.advance();
                var elems: std.ArrayList(ast.Expr) = .empty;

                p.skipNewlines();
                if (p.peek() != .r_bracket) {
                    while (true) {
                        p.skipNewlines();
                        const e = try p.parseExpr() orelse return null;
                        try elems.append(p.arena, e);
                        p.skipNewlines();
                        if (p.peek() != .comma) break;
                        _ = p.advance();
                        p.skipNewlines();
                        if (p.peek() == .r_bracket) break;
                    }
                }

                p.skipNewlines();
                const close = try p.expect(.r_bracket, "expected `]`", "add `]` to close the array") orelse return null;

                return .{ .array_lit = .{
                    .elems = try elems.toOwnedSlice(p.arena),
                    .span = Span.merge(open.span, close.span),
                } };
            },
            .string => {
                const t = p.advance();
                return .{ .string = .{ .value = t.value, .span = t.span } };
            },
            .int => {
                const t = p.advance();
                return .{ .int = .{ .text = t.value, .span = t.span } };
            },
            .l_paren => {
                _ = p.advance();
                const inner = try p.parseExpr() orelse return null;
                _ = try p.expect(.r_paren, "expected `)`", "add `)` to close the group") orelse return null;
                return inner;
            },
            .ident => {
                if (p.tokens[p.pos + 1].kind == .l_paren) return try p.parseCall();
                if (!p.no_struct_lit and p.tokens[p.pos + 1].kind == .l_brace and startsUpper(p.current().value)) {
                    return try p.parseStructLit();
                }
                const t = p.advance();
                return .{ .var_ref = .{ .name = t.value, .span = t.span } };
            },
            else => {
                try p.diags.err(
                    .unexpected_token,
                    p.current().span,
                    "expected an expression",
                    "expected a value, a variable, or a function call",
                    null,
                );
                return null;
            },
        }
    }

    fn parseCall(p: *Parser) Error!?ast.Expr {
        const name = p.advance();
        _ = try p.expect(.l_paren, "expected `(` to start a call", null) orelse return null;

        var args: std.ArrayList(ast.Expr) = .empty;

        if (p.peek() != .r_paren) {
            while (true) {
                const arg = try p.parseExpr() orelse return null;
                try args.append(p.arena, arg);
                if (p.peek() != .comma) break;
                _ = p.advance();
            }
        }

        const close = try p.expect(.r_paren, "expected `)`", "add `)` to close the call") orelse return null;

        return .{ .call = .{
            .callee = name.value,
            .callee_span = name.span,
            .args = try args.toOwnedSlice(p.arena),
            .span = Span.merge(name.span, close.span),
        } };
    }
};

fn startsUpper(name: []const u8) bool {
    return name.len > 0 and name[0] >= 'A' and name[0] <= 'Z';
}

pub fn parse(
    arena: std.mem.Allocator,
    tokens: []const Token,
    diags: *diagnostics.Diagnostics,
) !ast.Program {
    var p: Parser = .{ .arena = arena, .tokens = tokens, .diags = diags, .pos = 0 };
    return p.parseProgram();
}

const testing = std.testing;

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    diags: diagnostics.Diagnostics,
    program: ast.Program,

    fn deinit(p: *Parsed) void {
        p.diags.deinit();
        p.arena.deinit();
    }
};

fn parseText(gpa: std.mem.Allocator, text: []const u8) !Parsed {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    var d: diagnostics.Diagnostics = .init(gpa);
    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    const toks = try lexer.tokenize(arena_state.allocator(), file, &d);
    const program = try parse(arena_state.allocator(), toks, &d);
    return .{ .arena = arena_state, .diags = d, .program = program };
}

test "parses hello world" {
    var p = try parseText(testing.allocator, "fn main() {\n    println(\"hi\")\n}\n");
    defer p.deinit();

    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), p.program.fns.len);

    const f = p.program.fns[0];
    try testing.expectEqualStrings("main", f.name);
    try testing.expectEqual(@as(usize, 1), f.body.stmts.len);

    const call = f.body.stmts[0].expr.call;
    try testing.expectEqualStrings("println", call.callee);
    try testing.expectEqual(@as(usize, 1), call.args.len);
    try testing.expectEqualStrings("hi", call.args[0].string.value);
}

test "parses an empty function body" {
    var p = try parseText(testing.allocator, "fn main() {\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), p.program.fns[0].body.stmts.len);
}

test "parses a body with no newline before the closing brace" {
    var p = try parseText(testing.allocator, "fn main() { println(\"hi\") }");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), p.program.fns[0].body.stmts.len);
}

test "parses several statements" {
    var p = try parseText(testing.allocator, "fn main() {\n    println(\"a\")\n    println(\"b\")\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 2), p.program.fns[0].body.stmts.len);
}

test "parses several functions" {
    var p = try parseText(testing.allocator, "fn a() {\n}\n\nfn b() {\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 2), p.program.fns.len);
}

test "parses nested calls and multiple arguments" {
    var p = try parseText(testing.allocator, "fn main() {\n    a(b(\"x\"), \"y\")\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());

    const call = p.program.fns[0].body.stmts[0].expr.call;
    try testing.expectEqual(@as(usize, 2), call.args.len);
    try testing.expectEqualStrings("b", call.args[0].call.callee);
    try testing.expectEqualStrings("y", call.args[1].string.value);
}

test "parses a call with no arguments" {
    var p = try parseText(testing.allocator, "fn main() {\n    helper()\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), p.program.fns[0].body.stmts[0].expr.call.args.len);
}

test "leading blank lines are skipped" {
    var p = try parseText(testing.allocator, "\n\n\nfn main() {\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), p.program.fns.len);
}

test "comments between items are skipped" {
    var p = try parseText(testing.allocator, "# a note\nfn main() {\n    # inner\n    println(\"hi\")\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), p.program.fns[0].body.stmts.len);
}

test "an empty program is valid" {
    var p = try parseText(testing.allocator, "\n\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), p.program.fns.len);
}

test "function span covers fn keyword through closing brace" {
    const text = "fn main() {\n}\n";
    var p = try parseText(testing.allocator, text);
    defer p.deinit();

    const f = p.program.fns[0];
    try testing.expectEqualStrings("fn main() {\n}", text[f.span.start..f.span.end]);
}

test "missing closing paren reports E0001" {
    var p = try parseText(testing.allocator, "fn main() {\n    println(\"hi\"\n}\n");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
    try testing.expectEqual(diagnostics.Code.unexpected_token, p.diags.list.items[0].code.?);
}

test "recovers and reports two separate errors" {
    var p = try parseText(testing.allocator, "fn main() {\n    $\n    $\n}\n");
    defer p.deinit();
    try testing.expect(p.diags.list.items.len >= 2);
}

test "a function without a body reports an error and does not hang" {
    var p = try parseText(testing.allocator, "fn main()\n");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
}

test "top level junk reports an error and still parses the next function" {
    var p = try parseText(testing.allocator, "banana\nfn main() {\n}\n");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), p.program.fns.len);
}

test "unterminated input does not hang" {
    var p = try parseText(testing.allocator, "fn main() {");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
}

test "a statement that is not a call reports an error" {
    var p = try parseText(testing.allocator, "fn main() {\n    \"loose\"\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqualStrings("loose", p.program.fns[0].body.stmts[0].expr.string.value);
}

test "junk after a statement reports an error" {
    var p = try parseText(testing.allocator, "fn main() {\n    println(\"a\") println(\"b\")\n}\n");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
}

test "a binary expression spans both operands" {
    const text = "fn main() {\n    println(12 + 345)\n}\n";
    var p = try parseText(testing.allocator, text);
    defer p.deinit();

    const arg = p.program.fns[0].body.stmts[0].expr.call.args[0];
    try testing.expectEqualStrings("12 + 345", text[arg.spanOf().start..arg.spanOf().end]);
}

test "a chained binary expression spans the whole chain" {
    const text = "fn main() {\n    println(1 + 2 * 3)\n}\n";
    var p = try parseText(testing.allocator, text);
    defer p.deinit();

    const arg = p.program.fns[0].body.stmts[0].expr.call.args[0];
    try testing.expectEqualStrings("1 + 2 * 3", text[arg.spanOf().start..arg.spanOf().end]);
}

test "missing function name does not hang" {
    var p = try parseText(testing.allocator, "fn () {\n}\n");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
}
