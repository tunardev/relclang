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
const expr_mod = @import("expr.zig");
const lowerExpr = expr_mod.lowerExpr;
const lowerWithExpected = expr_mod.lowerWithExpected;

pub fn lowerStructLit(f: *Fn, s: ast.StructLit) Error!tir.Expr {
    if (f.symbols.templateIndex(s.name)) |tpl_index| {
        return lowerGenericStructLit(f, s, tpl_index);
    }

    const index = f.symbols.structIndex(s.name) orelse {
        try f.diags.err(
            .unknown_struct,
            s.name_span,
            try f.diags.fmt("unknown struct `{s}`", .{s.name}),
            "not defined anywhere",
            null,
        );
        for (s.fields) |field| _ = try lowerExpr(f, field.value);
        return .{ .struct_lit = .{ .strukt = 0, .fields = &.{}, .ty = .invalid, .span = s.span } };
    };

    const def = f.symbols.structs.items[index];
    const slots = try f.arena.alloc(tir.Expr, def.fields.len);
    const filled = try f.gpa.alloc(bool, def.fields.len);
    defer f.gpa.free(filled);
    @memset(filled, false);

    for (def.fields, 0..) |field, i| {
        slots[i] = .{ .int_const = .{ .value = 0, .ty = field.ty, .span = s.span } };
    }

    for (s.fields) |init_field| {
        const maybe_slot = def.fieldIndex(init_field.name);
        const expect: ?Type = if (maybe_slot) |slot| def.fields[slot].ty else null;
        const value = try lowerWithExpected(f, init_field.value, expect);

        const slot = maybe_slot orelse {
            try f.diags.err(
                .unknown_field,
                init_field.name_span,
                try f.diags.fmt("`{s}` has no field `{s}`", .{ def.name, init_field.name }),
                "unknown field",
                null,
            );
            continue;
        };

        if (filled[slot]) {
            try f.diags.err(
                .duplicate_binding,
                init_field.name_span,
                try f.diags.fmt("field `{s}` is set twice", .{init_field.name}),
                "duplicate field",
                null,
            );
        }
        filled[slot] = true;

        const want = def.fields[slot].ty;
        const got = value.typeOf();
        if (!got.isInvalid() and !Type.eql(want, got)) {
            try f.diags.err(
                .type_mismatch,
                init_field.value.spanOf(),
                "field type mismatch",
                try f.diags.fmt("expected `{s}`, found `{s}`", .{ try f.tyName(want), try f.tyName(got) }),
                null,
            );
        }

        slots[slot] = value;
    }

    for (def.fields, 0..) |field, i| {
        if (!filled[i]) {
            try f.diags.err(
                .missing_field,
                s.span,
                try f.diags.fmt("missing field `{s}` in `{s}`", .{ field.name, def.name }),
                "this field is never set",
                null,
            );
        }
    }

    try f.hoistList(slots);

    return .{ .struct_lit = .{
        .strukt = index,
        .fields = slots,
        .ty = .{ .strukt = index },
        .span = s.span,
    } };
}

pub fn lowerGenericStructLit(f: *Fn, s: ast.StructLit, tpl_index: u32) Error!tir.Expr {
    const tpl = f.symbols.templates.items[tpl_index];
    const template_def = tpl.struct_def.?;

    const bound = try f.gpa.alloc(?Type, tpl.type_param_count);
    defer f.gpa.free(bound);
    @memset(bound, null);

    var values: std.ArrayList(tir.Expr) = .empty;
    for (s.fields) |init_field| {
        const value = try lowerExpr(f, init_field.value);
        try values.append(f.arena, value);

        if (template_def.fieldIndex(init_field.name)) |slot| {
            const actual = value.typeOf();
            if (!actual.isInvalid()) _ = types.unify(template_def.fields[slot].ty, actual, bound);
        }
    }

    if (f.expected) |want| {
        if (want == .strukt) {
            for (f.symbols.instances.items) |inst| {
                if (inst.template != tpl_index or inst.index != want.strukt) continue;
                for (inst.args, 0..) |a, i| {
                    if (i < bound.len and bound[i] == null) bound[i] = a;
                }
                break;
            }
        }
    }

    const resolved = try f.arena.alloc(Type, tpl.type_param_count);
    for (bound, 0..) |b, i| {
        resolved[i] = b orelse {
            try f.diags.err(
                .cannot_infer,
                s.span,
                try f.diags.fmt("cannot infer the type parameters of `{s}`", .{tpl.name}),
                "no field determines them",
                "annotate the binding with the full type",
            );
            return .{ .struct_lit = .{ .strukt = 0, .fields = &.{}, .ty = .invalid, .span = s.span } };
        };
    }

    const instance = f.symbols.instantiate(tpl_index, resolved) catch return error.OutOfMemory;
    const index = instance.strukt;
    const def = f.symbols.structs.items[index];

    const slots = try f.arena.alloc(tir.Expr, def.fields.len);
    const filled = try f.gpa.alloc(bool, def.fields.len);
    defer f.gpa.free(filled);
    @memset(filled, false);

    for (def.fields, 0..) |field, i| {
        slots[i] = .{ .int_const = .{ .value = 0, .ty = field.ty, .span = s.span } };
    }

    for (s.fields, values.items) |init_field, value| {
        const slot = def.fieldIndex(init_field.name) orelse {
            try f.diags.err(
                .unknown_field,
                init_field.name_span,
                try f.diags.fmt("`{s}` has no field `{s}`", .{ def.name, init_field.name }),
                "unknown field",
                null,
            );
            continue;
        };

        if (filled[slot]) {
            try f.diags.err(
                .duplicate_binding,
                init_field.name_span,
                try f.diags.fmt("field `{s}` is set twice", .{init_field.name}),
                "duplicate field",
                null,
            );
        }
        filled[slot] = true;

        const want = def.fields[slot].ty;
        const got = value.typeOf();
        if (!got.isInvalid() and !Type.eql(want, got)) {
            try f.diags.err(
                .type_mismatch,
                init_field.value.spanOf(),
                "field type mismatch",
                try f.diags.fmt("expected `{s}`, found `{s}`", .{ try f.tyName(want), try f.tyName(got) }),
                null,
            );
        }

        slots[slot] = value;
    }

    for (def.fields, 0..) |field, i| {
        if (!filled[i]) {
            try f.diags.err(
                .missing_field,
                s.span,
                try f.diags.fmt("missing field `{s}` in `{s}`", .{ field.name, def.name }),
                "this field is never set",
                null,
            );
        }
    }

    try f.hoistList(slots);

    return .{ .struct_lit = .{
        .strukt = index,
        .fields = slots,
        .ty = .{ .strukt = index },
        .span = s.span,
    } };
}

pub fn lowerEnumLit(
    f: *Fn,
    ref_in: resolve.VariantRef,
    args: []const tir.Expr,
    arg_spans: []const source.Span,
    span: Span,
) Error!tir.Expr {
    var ref = ref_in;

    if (ref.from_template) {
        const tpl = f.symbols.templates.items[ref.enumeration];
        const template_def = tpl.enum_def.?;
        const declared = template_def.variants[ref.variant].payload;

        const bound = try f.gpa.alloc(?Type, tpl.type_param_count);
        defer f.gpa.free(bound);
        @memset(bound, null);

        if (declared.len == args.len) {
            for (declared, args) |want, arg| {
                const actual = arg.typeOf();
                if (actual.isInvalid()) continue;
                _ = types.unify(want, actual, bound);
            }
        }

        if (f.expected) |want| {
            if (want == .enumeration) {
                for (f.symbols.instances.items) |inst| {
                    if (inst.template != ref.enumeration) continue;
                    if (inst.index != want.enumeration) continue;
                    for (inst.args, 0..) |a, i| {
                        if (i < bound.len and bound[i] == null) bound[i] = a;
                    }
                    break;
                }
            }
        }

        const resolved = try f.arena.alloc(Type, tpl.type_param_count);
        for (bound, 0..) |b, i| {
            resolved[i] = b orelse {
                try f.diags.err(
                    .cannot_infer,
                    span,
                    try f.diags.fmt("cannot infer the type parameters of `{s}`", .{tpl.name}),
                    "no argument determines them",
                    "annotate the binding, as in `let x: Option<Int> = None`",
                );
                return .{ .enum_lit = .{
                    .enumeration = 0,
                    .variant = ref.variant,
                    .payload = args,
                    .ty = .invalid,
                    .span = span,
                } };
            };
        }

        const instance = f.symbols.instantiate(ref.enumeration, resolved) catch return error.OutOfMemory;
        ref = .{ .enumeration = instance.enumeration, .variant = ref.variant, .from_template = false };
    }

    const def = f.symbols.enums.items[ref.enumeration];
    const variant = def.variants[ref.variant];

    if (args.len != variant.payload.len) {
        try f.diags.err(
            .wrong_arg_count,
            span,
            try f.diags.fmt("`{s}` carries {d} {s}", .{
                variant.name,
                variant.payload.len,
                if (variant.payload.len == 1) "value" else "values",
            }),
            try f.diags.fmt("expected {d}, found {d}", .{ variant.payload.len, args.len }),
            null,
        );
    } else {
        for (args, 0..) |arg, i| {
            const got = arg.typeOf();
            if (!got.isInvalid() and !Type.eql(variant.payload[i], got)) {
                try f.diags.err(
                    .type_mismatch,
                    arg_spans[i],
                    "variant payload type mismatch",
                    try f.diags.fmt("expected `{s}`, found `{s}`", .{
                        try f.tyName(variant.payload[i]),
                        try f.tyName(got),
                    }),
                    null,
                );
            }
        }
    }

    return .{ .enum_lit = .{
        .enumeration = ref.enumeration,
        .variant = ref.variant,
        .payload = args,
        .ty = .{ .enumeration = ref.enumeration },
        .span = span,
    } };
}
