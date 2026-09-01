const std = @import("std");
const source = @import("../../support/source.zig");
const ast = @import("../../syntax/ast.zig");
const tir = @import("../../ir/tir.zig");
const types = @import("../types.zig");

const Span = source.Span;
const Type = types.Type;

const ctx = @import("context.zig");
const Error = ctx.Error;
const Fn = ctx.Fn;
const expr_mod = @import("expr.zig");
const lowerExpr = expr_mod.lowerExpr;
const lowerWithExpected = expr_mod.lowerWithExpected;
const autoDeref = expr_mod.autoDeref;

fn throughRef(expr: tir.Expr) ?bool {
    return switch (expr) {
        .deref => |d| blk: {
            const ty = d.operand.typeOf();
            break :blk if (ty == .ref) ty.ref.mutable else null;
        },
        .field => |x| throughRef(x.base.*),
        .index => |x| throughRef(x.base.*),
        else => null,
    };
}

pub fn lowerMatch(f: *Fn, m: ast.Match) Error!tir.Expr {
    const raw = try lowerExpr(f, m.scrutinee.*);
    const scrutinee = try autoDeref(f, try f.hoistOwning(raw));
    const scrut_ty = scrutinee.typeOf();

    if (scrut_ty != .enumeration) {
        if (!scrut_ty.isInvalid()) {
            try f.diags.err(
                .bad_pattern,
                m.scrutinee.spanOf(),
                try f.diags.fmt("cannot match on `{s}`", .{try f.tyName(scrut_ty)}),
                "only enums can be matched",
                null,
            );
        }
        for (m.arms) |arm| _ = try lowerExpr(f, arm.body);
        return .{ .match = .{
            .scrutinee = try f.box(scrutinee),
            .enumeration = 0,
            .by_ref = false,
            .arms = &.{},
            .ty = .invalid,
            .span = m.span,
        } };
    }

    const enum_index = scrut_ty.enumeration;
    const def = f.symbols.enums.items[enum_index];

    const ref_mutable = throughRef(scrutinee);
    const by_ref = ref_mutable != null;
    const origin = if (by_ref) f.rootSlotOf(scrutinee) else null;

    const covered = try f.gpa.alloc(bool, def.variants.len);
    defer f.gpa.free(covered);
    @memset(covered, false);

    const arm_expected = f.expected;
    var has_wildcard = false;
    var saw_invalid = false;
    var arms: std.ArrayList(tir.MatchArm) = .empty;
    var result_ty: ?Type = null;

    for (m.arms) |arm| {
        f.depth += 1;
        const mark = f.bindings.items.len;

        var variant_index: ?u32 = null;
        var slots: []u32 = &.{};

        switch (arm.pattern) {
            .wildcard => {
                if (has_wildcard) {
                    try f.diags.err(
                        .unreachable_arm,
                        arm.pattern.spanOf(),
                        "this arm is unreachable",
                        "an earlier `_` already matches everything",
                        null,
                    );
                }
                has_wildcard = true;
            },
            .variant => |v| {
                const index = def.variantIndex(v.name) orelse blk: {
                    try f.diags.err(
                        .bad_pattern,
                        v.name_span,
                        try f.diags.fmt("`{s}` has no variant `{s}`", .{ def.name, v.name }),
                        "unknown variant",
                        null,
                    );
                    break :blk null;
                };

                if (index) |vi| {
                    if (covered[vi] or has_wildcard) {
                        try f.diags.err(
                            .unreachable_arm,
                            v.name_span,
                            try f.diags.fmt("`{s}` is already handled", .{v.name}),
                            "this arm is unreachable",
                            null,
                        );
                    }
                    covered[vi] = true;
                    variant_index = vi;

                    const payload = def.variants[vi].payload;
                    if (v.bindings.len != payload.len) {
                        try f.diags.err(
                            .bad_pattern,
                            v.span,
                            try f.diags.fmt("`{s}` carries {d} {s}", .{
                                v.name,
                                payload.len,
                                if (payload.len == 1) "value" else "values",
                            }),
                            try f.diags.fmt("expected {d}, found {d}", .{ payload.len, v.bindings.len }),
                            null,
                        );
                        for (v.bindings) |binding| _ = try f.declare(binding.name, .invalid);
                    } else {
                        slots = try f.arena.alloc(u32, payload.len);
                        for (v.bindings, 0..) |binding, i| {
                            var bound_ty = payload[i];
                            if (by_ref and !types.isCopy(bound_ty)) {
                                const target = try f.arena.create(Type);
                                target.* = bound_ty;
                                bound_ty = .{ .ref = .{ .mutable = ref_mutable.?, .target = target } };
                            }
                            slots[i] = try f.declare(binding.name, bound_ty);
                            if (bound_ty == .ref) f.locals.items[slots[i]].borrows_local = origin;
                        }
                    }
                }
            },
        }

        const temp_mark = f.temps.items.len;
        const body = try lowerWithExpected(f, arm.body, arm_expected);
        const temps = try f.takeTemps(temp_mark);
        const body_ty = body.typeOf();

        if (result_ty) |want| {
            if (!body_ty.isInvalid() and !want.isInvalid() and !Type.eql(want, body_ty)) {
                try f.diags.err(
                    .type_mismatch,
                    arm.body.spanOf(),
                    "match arms must all have the same type",
                    try f.diags.fmt("expected `{s}`, found `{s}`", .{ try f.tyName(want), try f.tyName(body_ty) }),
                    null,
                );
            }
        } else if (!body_ty.isInvalid()) {
            result_ty = body_ty;
        }

        if (body_ty.isInvalid()) saw_invalid = true;

        try arms.append(f.arena, .{
            .variant = variant_index,
            .bindings = slots,
            .temps = temps,
            .body = body,
            .span = arm.span,
        });

        f.bindings.shrinkRetainingCapacity(mark);
        f.depth -= 1;
    }

    if (!has_wildcard) {
        var missing: std.ArrayList(u8) = .empty;
        defer missing.deinit(f.gpa);
        var count: usize = 0;

        for (def.variants, 0..) |variant, i| {
            if (covered[i]) continue;
            if (count > 0) try missing.appendSlice(f.gpa, ", ");
            try missing.appendSlice(f.gpa, variant.name);
            count += 1;
        }

        if (count > 0) {
            try f.diags.err(
                .non_exhaustive,
                m.span,
                try f.diags.fmt("match on `{s}` is not exhaustive", .{def.name}),
                try f.diags.fmt("missing {s}", .{missing.items}),
                "add the missing arms, or a `_` arm",
            );
        }
    }

    return .{ .match = .{
        .scrutinee = try f.box(scrutinee),
        .enumeration = enum_index,
        .by_ref = by_ref,
        .arms = try arms.toOwnedSlice(f.arena),
        .ty = result_ty orelse (if (saw_invalid) Type.invalid else Type.void),
        .span = m.span,
    } };
}
