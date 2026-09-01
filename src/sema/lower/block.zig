const std = @import("std");
const source = @import("../../support/source.zig");
const diagnostics = @import("../../support/diagnostics.zig");
const ast = @import("../../syntax/ast.zig");
const tir = @import("../../ir/tir.zig");
const types = @import("../types.zig");
const resolve = @import("../resolve.zig");
const typecheck = @import("../type_rules.zig");

const Span = source.Span;
const Type = types.Type;

const ctx = @import("context.zig");
const Error = ctx.Error;
const Fn = ctx.Fn;
const Place = ctx.Place;
const expr_mod = @import("expr.zig");
const lowerExpr = expr_mod.lowerExpr;
const lowerWithExpected = expr_mod.lowerWithExpected;
const resolveLocalType = expr_mod.resolveLocalType;

pub fn rootPlace(f: *Fn, expr: tir.Expr) ?Place {
    return switch (expr) {
        .local_ref => |l| .{
            .slot = l.slot,
            .is_mut = f.locals.items[l.slot].is_mut,
            .name = f.locals.items[l.slot].name,
        },
        .field => |fa| rootPlace(f, fa.base.*),
        .index => |x| rootPlace(f, x.base.*),
        .deref => |d| derefPlace(f, d.operand.*),
        else => null,
    };
}

pub fn derefPlace(f: *Fn, expr: tir.Expr) ?Place {
    const ty = expr.typeOf();
    if (ty != .ref) return rootPlace(f, expr);

    if (rootPlace(f, expr)) |place| {
        return .{ .slot = place.slot, .is_mut = ty.ref.mutable, .name = place.name };
    }
    return null;
}

pub fn lowerAssign(f: *Fn, a: ast.Assign) Error!?tir.Stmt {
    const target = try lowerExpr(f, a.target);
    const value = try lowerExpr(f, a.value);

    const place = rootPlace(f, target) orelse {
        if (!target.typeOf().isInvalid()) {
            try f.diags.err(
                .not_assignable,
                a.target.spanOf(),
                "this expression cannot be assigned to",
                "not a variable, field or element",
                null,
            );
        }
        return null;
    };

    if (!place.is_mut) {
        try f.diags.err(
            .immutable_assign,
            a.target.spanOf(),
            try f.diags.fmt("`{s}` is not mutable", .{place.name}),
            "cannot assign to this",
            try f.diags.fmt("declare it with `let mut {s} = ...`", .{place.name}),
        );
    }

    f.locals.items[place.slot].assigned = true;

    const want = target.typeOf();
    const got = value.typeOf();
    if (!want.isInvalid() and !got.isInvalid() and !Type.eql(want, got)) {
        try f.diags.err(
            .type_mismatch,
            a.value.spanOf(),
            "assigned value has the wrong type",
            try f.diags.fmt("expected `{s}`, found `{s}`", .{ try f.tyName(want), try f.tyName(got) }),
            null,
        );
    }

    return .{ .assign = .{ .target = target, .value = value, .span = a.span } };
}

pub fn lowerBlock(f: *Fn, block: ast.Block, wants_value: bool) Error!tir.Block {
    f.depth += 1;
    const mark = f.bindings.items.len;
    defer {
        f.bindings.shrinkRetainingCapacity(mark);
        f.depth -= 1;
    }

    var stmts: std.ArrayList(tir.Stmt) = .empty;
    var result: ?*const tir.Expr = null;
    const last = block.stmts.len;

    const outer_expected = f.expected;
    defer f.expected = outer_expected;

    for (block.stmts, 0..) |stmt, i| {
        const is_last = i + 1 == last;
        f.expected = if (is_last and wants_value) outer_expected else null;
        const lowered = try lowerStmt(f, stmt, is_last and wants_value) orelse {
            f.temps.clearRetainingCapacity();
            continue;
        };

        for (f.temps.items) |temp| try stmts.append(f.arena, temp);
        f.temps.clearRetainingCapacity();

        if (is_last and wants_value and lowered == .expr) {
            result = try f.box(lowered.expr);
            continue;
        }

        if (lowered == .expr) {
            const ty = lowered.expr.typeOf();
            if (ty != .void and !ty.isInvalid()) {
                try f.diags.err(
                    .unused_value,
                    lowered.expr.spanOf(),
                    try f.diags.fmt("this `{s}` value is not used", .{try f.tyName(ty)}),
                    "the value is discarded",
                    "bind it with `let`, or remove it",
                );
            }
        }

        try stmts.append(f.arena, lowered);
    }

    return .{ .stmts = try stmts.toOwnedSlice(f.arena), .result = result };
}

pub fn lowerIf(f: *Fn, node: ast.If, wants_value: bool) Error!tir.Expr {
    const cond = try lowerExpr(f, node.cond.*);
    const cond_ty = cond.typeOf();

    if (!cond_ty.isInvalid() and cond_ty != .bool) {
        try f.diags.err(
            .type_mismatch,
            node.cond.spanOf(),
            "a condition must be a `Bool`",
            try f.diags.fmt("expected `Bool`, found `{s}`", .{try f.tyName(cond_ty)}),
            null,
        );
    }

    const has_else = node.else_block != null or node.else_if != null;
    const want = wants_value;

    const then_block = try lowerBlock(f, node.then_block, want);

    var else_block: ?tir.Block = null;

    if (node.else_if) |nested| {
        const inner = try lowerIf(f, nested.if_expr, want);
        if (want) {
            else_block = .{ .stmts = &.{}, .result = try f.box(inner) };
        } else {
            var one: std.ArrayList(tir.Stmt) = .empty;
            try one.append(f.arena, .{ .expr = inner });
            else_block = .{ .stmts = try one.toOwnedSlice(f.arena), .result = null };
        }
    } else if (node.else_block) |b| {
        else_block = try lowerBlock(f, b, want);
    }

    var ty: Type = .void;

    if (wants_value and !has_else) {
        try f.diags.err(
            .missing_return,
            node.span,
            "an `if` used as a value needs an `else`",
            "there is no `else` branch",
            "add `else { ... }`",
        );
        return .{ .if_expr = .{
            .cond = try f.box(cond),
            .then_block = then_block,
            .else_block = null,
            .ty = .invalid,
            .span = node.span,
        } };
    }

    if (want) {
        const then_ty = if (then_block.result) |r| r.typeOf() else Type.void;
        const else_ty = if (else_block) |b| (if (b.result) |r| r.typeOf() else Type.void) else Type.void;

        if (!then_ty.isInvalid() and !else_ty.isInvalid() and !Type.eql(then_ty, else_ty)) {
            try f.diags.err(
                .type_mismatch,
                node.span,
                "if branches must have the same type",
                try f.diags.fmt("`then` is `{s}` but `else` is `{s}`", .{
                    try f.tyName(then_ty),
                    try f.tyName(else_ty),
                }),
                null,
            );
            ty = .invalid;
        } else {
            ty = if (then_ty.isInvalid()) else_ty else then_ty;
        }
    }

    return .{ .if_expr = .{
        .cond = try f.box(cond),
        .then_block = then_block,
        .else_block = else_block,
        .ty = ty,
        .span = node.span,
    } };
}

pub fn lowerStmt(f: *Fn, stmt: ast.Stmt, wants_value: bool) Error!?tir.Stmt {
    switch (stmt) {
        .expr => |e| {
            if (e == .if_expr) return .{ .expr = try lowerIf(f, e.if_expr, wants_value) };
            return .{ .expr = try lowerExpr(f, e) };
        },
        .assign => |a| return lowerAssign(f, a),

        .ret => |r| {
            var value: ?tir.Expr = null;

            if (r.value) |expr| {
                const lowered = try lowerWithExpected(f, expr, f.ret_ty);
                const got = lowered.typeOf();
                if (!got.isInvalid() and !Type.eql(got, f.ret_ty)) {
                    try f.diags.err(
                        .missing_return,
                        expr.spanOf(),
                        "returned value has the wrong type",
                        try f.diags.fmt("expected `{s}`, found `{s}`", .{
                            try f.tyName(f.ret_ty),
                            try f.tyName(got),
                        }),
                        null,
                    );
                }
                value = lowered;
            } else if (f.ret_ty != .void) {
                try f.diags.err(
                    .missing_return,
                    r.span,
                    "this function must return a value",
                    try f.diags.fmt("expected `{s}`", .{try f.tyName(f.ret_ty)}),
                    null,
                );
            }

            return .{ .ret = .{ .value = value, .span = r.span } };
        },
        .let => |l| {
            var annotation: ?Type = null;
            if (l.ty) |ty_expr| annotation = try f.subst(try resolveLocalType(f, ty_expr));

            const init_expr = try lowerWithExpected(f, l.init, annotation);
            var ty = init_expr.typeOf();

            if (annotation) |annotated| {
                if (!annotated.isInvalid() and !ty.isInvalid() and !Type.eql(annotated, ty)) {
                    try f.diags.err(
                        .type_mismatch,
                        l.init.spanOf(),
                        "type does not match the annotation",
                        try f.diags.fmt("expected `{s}`, found `{s}`", .{
                            try f.tyName(annotated),
                            try f.tyName(ty),
                        }),
                        null,
                    );
                }
                ty = annotated;
            }

            if (ty == .void) {
                try f.diags.err(
                    .invalid_operand,
                    l.init.spanOf(),
                    "cannot bind a value of type `Void`",
                    "this expression produces no value",
                    null,
                );
                ty = .invalid;
            }

            if (f.declaredAtDepth(l.name)) {
                try f.diags.err(
                    .duplicate_binding,
                    l.name_span,
                    try f.diags.fmt("`{s}` is already defined in this scope", .{l.name}),
                    "duplicate binding",
                    "shadowing is not allowed yet, pick another name",
                );
            }

            const slot = try f.declareMut(l.name, ty, l.is_mut);

            if (ty == .ref) {
                if (init_expr == .borrow) {
                    f.locals.items[slot].borrows_local = f.rootSlotOf(init_expr.borrow.operand.*);
                } else if (init_expr == .local_ref) {
                    f.locals.items[slot].borrows_local = f.locals.items[init_expr.local_ref.slot].borrows_local;
                } else if (init_expr == .vec_op and init_expr.vec_op.args.len > 0) {
                    f.locals.items[slot].borrows_local = f.rootSlotOf(init_expr.vec_op.args[0]);
                }
            }

            return .{ .let = .{
                .slot = slot,
                .init = init_expr,
                .ty = ty,
                .span = l.span,
            } };
        },
    }
}
