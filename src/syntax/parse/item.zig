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
const parseType = @import("type.zig").parseType;
const peek = @import("core.zig").peek;
const recoverInBlock = @import("core.zig").recoverInBlock;
const recoverToTopLevel = @import("core.zig").recoverToTopLevel;
const skipNewlines = @import("core.zig").skipNewlines;

pub fn parseProgram(p: *Parser) Error!ast.Program {
    var fns: std.ArrayList(ast.Fn) = .empty;
    var structs: std.ArrayList(ast.StructDecl) = .empty;
    var enums: std.ArrayList(ast.EnumDecl) = .empty;
    var traits: std.ArrayList(ast.TraitDecl) = .empty;
    var impls: std.ArrayList(ast.ImplDecl) = .empty;

    while (true) {
        skipNewlines(p);
        if (peek(p) == .eof) break;

        switch (peek(p)) {
            .kw_fn => if (try parseFn(p)) |f| try fns.append(p.arena, f),
            .kw_struct => if (try parseStruct(p)) |d| try structs.append(p.arena, d),
            .kw_enum => if (try parseEnum(p)) |d| try enums.append(p.arena, d),
            .kw_trait => if (try parseTrait(p)) |d| try traits.append(p.arena, d),
            .kw_impl => if (try parseImpl(p)) |d| try impls.append(p.arena, d),
            else => {
                try p.diags.err(
                    .unexpected_token,
                    current(p).span,
                    "expected a top level definition",
                    "only `fn`, `struct`, `enum`, `trait` and `impl` are allowed here",
                    null,
                );
                recoverToTopLevel(p);
            },
        }
    }

    return .{
        .fns = try fns.toOwnedSlice(p.arena),
        .structs = try structs.toOwnedSlice(p.arena),
        .enums = try enums.toOwnedSlice(p.arena),
        .traits = try traits.toOwnedSlice(p.arena),
        .impls = try impls.toOwnedSlice(p.arena),
    };
}

pub fn parseFn(p: *Parser) Error!?ast.Fn {
    const kw = advance(p);

    const name_tok = try expect(p, .ident, "expected a function name", null) orelse {
        recoverToTopLevel(p);
        return null;
    };

    const type_params = try parseTypeParams(p) orelse {
        recoverToTopLevel(p);
        return null;
    };

    const list = try parseParamList(p) orelse {
        recoverToTopLevel(p);
        return null;
    };

    var ret_ty: ?ast.TypeExpr = null;
    if (peek(p) == .arrow) {
        _ = advance(p);
        ret_ty = try parseType(p) orelse {
            recoverToTopLevel(p);
            return null;
        };
    }

    skipNewlines(p);

    const body = try parseBlock(p) orelse {
        recoverToTopLevel(p);
        return null;
    };

    return .{
        .name = name_tok.value,
        .name_span = name_tok.span,
        .type_params = type_params,
        .has_self = list.has_self,
        .params = list.params,
        .ret_ty = ret_ty,
        .body = body,
        .span = Span.merge(kw.span, body.span),
    };
}

pub fn parseStruct(p: *Parser) Error!?ast.StructDecl {
    const kw = advance(p);

    const name_tok = try expect(p, .ident, "expected a struct name", null) orelse {
        recoverToTopLevel(p);
        return null;
    };

    const type_params = try parseTypeParams(p) orelse {
        recoverToTopLevel(p);
        return null;
    };

    skipNewlines(p);
    _ = try expect(p, .l_brace, "expected `{`", null) orelse {
        recoverToTopLevel(p);
        return null;
    };

    var fields: std.ArrayList(ast.FieldDecl) = .empty;

    while (true) {
        skipNewlines(p);
        if (peek(p) == .r_brace or peek(p) == .eof) break;

        const before = p.pos;

        const fname = try expect(p, .ident, "expected a field name", null) orelse {
            recoverInBlock(p);
            if (p.pos == before) p.pos += 1;
            continue;
        };
        _ = try expect(p, .colon, "expected `:`", "every field needs a type") orelse {
            recoverInBlock(p);
            if (p.pos == before) p.pos += 1;
            continue;
        };
        const fty = try parseType(p) orelse {
            recoverInBlock(p);
            if (p.pos == before) p.pos += 1;
            continue;
        };

        try fields.append(p.arena, .{ .name = fname.value, .name_span = fname.span, .ty = fty });

        if (peek(p) == .comma) _ = advance(p);
        if (p.pos == before) p.pos += 1;
    }

    const close = try expect(p, .r_brace, "expected `}`", "the struct body is never closed") orelse current(p);

    return .{
        .name = name_tok.value,
        .name_span = name_tok.span,
        .type_params = type_params,
        .fields = try fields.toOwnedSlice(p.arena),
        .span = Span.merge(kw.span, close.span),
    };
}

pub fn parseEnum(p: *Parser) Error!?ast.EnumDecl {
    const kw = advance(p);

    const name_tok = try expect(p, .ident, "expected an enum name", null) orelse {
        recoverToTopLevel(p);
        return null;
    };

    const type_params = try parseTypeParams(p) orelse {
        recoverToTopLevel(p);
        return null;
    };

    skipNewlines(p);
    _ = try expect(p, .l_brace, "expected `{`", null) orelse {
        recoverToTopLevel(p);
        return null;
    };

    var variants: std.ArrayList(ast.VariantDecl) = .empty;

    while (true) {
        skipNewlines(p);
        if (peek(p) == .r_brace or peek(p) == .eof) break;

        const before = p.pos;

        const vname = try expect(p, .ident, "expected a variant name", null) orelse {
            recoverInBlock(p);
            if (p.pos == before) p.pos += 1;
            continue;
        };

        var payload: std.ArrayList(ast.TypeExpr) = .empty;
        if (peek(p) == .l_paren) {
            _ = advance(p);
            if (peek(p) != .r_paren) {
                while (true) {
                    const ty = try parseType(p) orelse break;
                    try payload.append(p.arena, ty);
                    if (peek(p) != .comma) break;
                    _ = advance(p);
                }
            }
            _ = try expect(p, .r_paren, "expected `)`", null) orelse {
                recoverInBlock(p);
                if (p.pos == before) p.pos += 1;
                continue;
            };
        }

        try variants.append(p.arena, .{
            .name = vname.value,
            .name_span = vname.span,
            .payload = try payload.toOwnedSlice(p.arena),
        });

        if (peek(p) == .comma) _ = advance(p);
        if (p.pos == before) p.pos += 1;
    }

    const close = try expect(p, .r_brace, "expected `}`", "the enum body is never closed") orelse current(p);

    return .{
        .name = name_tok.value,
        .name_span = name_tok.span,
        .type_params = type_params,
        .variants = try variants.toOwnedSlice(p.arena),
        .span = Span.merge(kw.span, close.span),
    };
}

pub fn parseTrait(p: *Parser) Error!?ast.TraitDecl {
    const kw = advance(p);

    const name_tok = try expect(p, .ident, "expected a trait name", null) orelse {
        recoverToTopLevel(p);
        return null;
    };

    skipNewlines(p);
    _ = try expect(p, .l_brace, "expected `{`", null) orelse {
        recoverToTopLevel(p);
        return null;
    };

    var methods: std.ArrayList(ast.MethodSig) = .empty;

    while (true) {
        skipNewlines(p);
        if (peek(p) == .r_brace or peek(p) == .eof) break;

        const before = p.pos;

        if (peek(p) != .kw_fn) {
            try p.diags.err(
                .unexpected_token,
                current(p).span,
                "expected a method signature",
                "a trait body holds `fn` signatures",
                null,
            );
            recoverInBlock(p);
            if (p.pos == before) p.pos += 1;
            continue;
        }

        const fn_kw = advance(p);
        const mname = try expect(p, .ident, "expected a method name", null) orelse {
            recoverInBlock(p);
            if (p.pos == before) p.pos += 1;
            continue;
        };

        const list = try parseParamList(p) orelse {
            recoverInBlock(p);
            if (p.pos == before) p.pos += 1;
            continue;
        };

        var ret_ty: ?ast.TypeExpr = null;
        if (peek(p) == .arrow) {
            _ = advance(p);
            ret_ty = try parseType(p);
        }

        try methods.append(p.arena, .{
            .name = mname.value,
            .name_span = mname.span,
            .params = list.params,
            .ret_ty = ret_ty,
            .span = Span.merge(fn_kw.span, mname.span),
        });

        if (p.pos == before) p.pos += 1;
    }

    const close = try expect(p, .r_brace, "expected `}`", "the trait body is never closed") orelse current(p);

    return .{
        .name = name_tok.value,
        .name_span = name_tok.span,
        .methods = try methods.toOwnedSlice(p.arena),
        .span = Span.merge(kw.span, close.span),
    };
}

pub fn parseImpl(p: *Parser) Error!?ast.ImplDecl {
    const kw = advance(p);

    const trait_tok = try expect(p, .ident, "expected a trait name", null) orelse {
        recoverToTopLevel(p);
        return null;
    };

    _ = try expect(p, .kw_for, "expected `for`", "write `impl Trait for Type`") orelse {
        recoverToTopLevel(p);
        return null;
    };

    const target = try parseType(p) orelse {
        recoverToTopLevel(p);
        return null;
    };

    skipNewlines(p);
    _ = try expect(p, .l_brace, "expected `{`", null) orelse {
        recoverToTopLevel(p);
        return null;
    };

    var methods: std.ArrayList(ast.Fn) = .empty;

    while (true) {
        skipNewlines(p);
        if (peek(p) == .r_brace or peek(p) == .eof) break;

        const before = p.pos;

        if (peek(p) != .kw_fn) {
            try p.diags.err(
                .unexpected_token,
                current(p).span,
                "expected a method",
                "an impl body holds `fn` definitions",
                null,
            );
            recoverInBlock(p);
            if (p.pos == before) p.pos += 1;
            continue;
        }

        if (try parseFn(p)) |m| try methods.append(p.arena, m);
        if (p.pos == before) p.pos += 1;
    }

    const close = try expect(p, .r_brace, "expected `}`", "the impl body is never closed") orelse current(p);

    return .{
        .trait_name = trait_tok.value,
        .trait_span = trait_tok.span,
        .target = target,
        .methods = try methods.toOwnedSlice(p.arena),
        .span = Span.merge(kw.span, close.span),
    };
}

pub fn parseParamList(p: *Parser) Error!?struct { params: []const ast.Param, has_self: bool } {
    _ = try expect(p, .l_paren, "expected `(`", null) orelse return null;

    var params: std.ArrayList(ast.Param) = .empty;
    var has_self = false;

    if (peek(p) != .r_paren) {
        if (peek(p) == .kw_self) {
            _ = advance(p);
            has_self = true;
            if (peek(p) == .comma) _ = advance(p);
        }

        while (peek(p) != .r_paren) {
            const pname = try expect(p, .ident, "expected a parameter name", null) orelse return null;
            _ = try expect(p, .colon, "expected `:`", "every parameter needs a type") orelse return null;
            const pty = try parseType(p) orelse return null;
            try params.append(p.arena, .{
                .name = pname.value,
                .name_span = pname.span,
                .ty = pty,
            });
            if (peek(p) != .comma) break;
            _ = advance(p);
        }
    }

    _ = try expect(p, .r_paren, "expected `)`", null) orelse return null;

    return .{ .params = try params.toOwnedSlice(p.arena), .has_self = has_self };
}

pub fn parseTypeParams(p: *Parser) Error!?[]const ast.TypeParam {
    var list: std.ArrayList(ast.TypeParam) = .empty;

    if (peek(p) != .lt) return try list.toOwnedSlice(p.arena);

    _ = advance(p);
    while (true) {
        const name = try expect(p, .ident, "expected a type parameter name", null) orelse return null;

        var bounds: std.ArrayList(ast.Bound) = .empty;
        if (peek(p) == .colon) {
            _ = advance(p);
            while (true) {
                const b = try expect(p, .ident, "expected a trait name", null) orelse return null;
                try bounds.append(p.arena, .{ .name = b.value, .span = b.span });
                if (peek(p) != .plus) break;
                _ = advance(p);
            }
        }

        try list.append(p.arena, .{
            .name = name.value,
            .span = name.span,
            .bounds = try bounds.toOwnedSlice(p.arena),
        });
        if (peek(p) != .comma) break;
        _ = advance(p);
    }
    _ = try expect(p, .gt, "expected `>`", "close the type parameters") orelse return null;

    return try list.toOwnedSlice(p.arena);
}
