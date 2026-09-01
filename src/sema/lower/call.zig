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
const literal_mod = @import("literal.zig");
const builtinOf = expr_mod.builtinOf;
const lowerEnumLit = literal_mod.lowerEnumLit;
const rootPlace = @import("block.zig").rootPlace;

pub fn lowerCall(f: *Fn, c: ast.Call) Error!tir.Expr {
    var declared: []const Type = &.{};
    if (f.symbols.lookup(c.callee)) |sym| {
        switch (sym) {
            .function => |target| {
                const raw = f.symbols.signature(target);
                if (!raw.isGeneric()) declared = raw.params;
            },
            .variant => |ref| {
                if (!ref.from_template) {
                    declared = f.symbols.enums.items[ref.enumeration].variants[ref.variant].payload;
                }
            },
            else => {},
        }
    }

    var args: std.ArrayList(tir.Expr) = .empty;
    for (c.args, 0..) |arg, i| {
        const want: ?Type = if (i < declared.len) declared[i] else null;
        try args.append(f.arena, try lowerWithExpected(f, arg, want));
    }
    const lowered = try args.toOwnedSlice(f.arena);
    try f.hoistList(lowered);

    const symbol = f.symbols.lookup(c.callee) orelse {
        try f.diags.err(
            .unknown_function,
            c.callee_span,
            try f.diags.fmt("unknown function `{s}`", .{c.callee}),
            "not defined anywhere",
            null,
        );
        return .{ .call_builtin = .{
            .builtin = .print_line,
            .args = lowered,
            .ty = .invalid,
            .span = c.span,
        } };
    };

    switch (symbol) {
        .variant => |ref| {
            const spans = try f.arena.alloc(source.Span, c.args.len);
            for (c.args, 0..) |arg, i| spans[i] = arg.spanOf();
            return lowerEnumLit(f, ref, lowered, spans, c.span);
        },
        .builtin => |b| {
            const want = b.arity();
            if (lowered.len != want) {
                try f.diags.err(
                    .wrong_arg_count,
                    c.span,
                    try f.diags.fmt("`{s}` takes {d} {s}", .{
                        c.callee,
                        want,
                        if (want == 1) "argument" else "arguments",
                    }),
                    try f.diags.fmt("expected {d}, found {d}", .{ want, lowered.len }),
                    null,
                );
            } else {
                for (lowered, 0..) |arg, i| {
                    const ty = arg.typeOf();
                    if (!ty.isInvalid() and !b.accepts(i, ty)) {
                        try f.diags.err(
                            .type_mismatch,
                            arg.spanOf(),
                            "argument type mismatch",
                            try f.diags.fmt("expected {s}, found `{s}`", .{ b.describeParam(i), try f.tyName(ty) }),
                            null,
                        );
                    }
                }
            }
            return .{ .call_builtin = .{
                .builtin = builtinOf(b),
                .args = lowered,
                .ty = b.resultType(),
                .span = c.span,
            } };
        },
        .function => |target| {
            const raw = f.symbols.signature(target);

            if (raw.isGeneric()) return lowerGenericCall(f, c, target, raw, lowered);

            const info = raw;
            if (lowered.len != info.params.len) {
                try f.diags.err(
                    .wrong_arg_count,
                    c.span,
                    try f.diags.fmt("`{s}` takes {d} {s}", .{
                        c.callee,
                        info.params.len,
                        if (info.params.len == 1) "argument" else "arguments",
                    }),
                    try f.diags.fmt("expected {d}, found {d}", .{ info.params.len, lowered.len }),
                    null,
                );
            } else {
                for (lowered, 0..) |arg, i| {
                    const ty = arg.typeOf();
                    if (!ty.isInvalid() and !Type.eql(ty, info.params[i])) {
                        try f.diags.err(
                            .type_mismatch,
                            arg.spanOf(),
                            "argument type mismatch",
                            try f.diags.fmt("expected `{s}`, found `{s}`", .{ try f.tyName(info.params[i]), try f.tyName(ty) }),
                            null,
                        );
                    }
                }
            }
            return .{ .call_function = .{
                .target = f.mono.ast_to_tir[target].?,
                .args = lowered,
                .ty = info.ret,
                .span = c.span,
            } };
        },
    }
}

pub fn lowerGenericCall(
    f: *Fn,
    c: ast.Call,
    target: usize,
    info: resolve.FnInfo,
    args: []const tir.Expr,
) Error!tir.Expr {
    if (args.len != info.params.len) {
        try f.diags.err(
            .wrong_arg_count,
            c.span,
            try f.diags.fmt("`{s}` takes {d} {s}", .{
                c.callee,
                info.params.len,
                if (info.params.len == 1) "argument" else "arguments",
            }),
            try f.diags.fmt("expected {d}, found {d}", .{ info.params.len, args.len }),
            null,
        );
        return .{ .call_builtin = .{ .builtin = .print_line, .args = args, .ty = .invalid, .span = c.span } };
    }

    const bound = try f.gpa.alloc(?Type, info.type_param_count);
    defer f.gpa.free(bound);
    @memset(bound, null);

    for (info.params, args) |declared, arg| {
        const actual = arg.typeOf();
        if (actual.isInvalid()) continue;
        if (!types.unify(declared, actual, bound)) {
            const want = try types.substitute(f.arena, declared, blk: {
                const partial = try f.arena.alloc(Type, bound.len);
                for (bound, 0..) |b, i| partial[i] = b orelse .invalid;
                break :blk partial;
            });
            try f.diags.err(
                .type_mismatch,
                arg.spanOf(),
                "argument type mismatch",
                try f.diags.fmt("expected `{s}`, found `{s}`", .{
                    try f.tyName(want),
                    try f.tyName(actual),
                }),
                null,
            );
        }
    }

    const resolved = try f.arena.alloc(Type, info.type_param_count);
    for (bound, 0..) |b, i| {
        resolved[i] = b orelse {
            try f.diags.err(
                .cannot_infer,
                c.span,
                try f.diags.fmt("cannot infer the type parameters of `{s}`", .{c.callee}),
                "no argument determines it",
                "annotate the arguments so the type can be worked out",
            );
            return .{ .call_builtin = .{ .builtin = .print_line, .args = args, .ty = .invalid, .span = c.span } };
        };
    }

    const bounds = f.symbols.bounds[target];
    for (resolved, 0..) |arg, i| {
        if (i >= bounds.len) break;
        const trait_index = bounds[i];
        if (trait_index == std.math.maxInt(u32)) continue;
        if (f.symbols.implements(arg, trait_index)) continue;

        try f.diags.err(
            .missing_impl,
            c.span,
            try f.diags.fmt("`{s}` does not implement `{s}`", .{
                try f.tyName(arg),
                f.symbols.traits[trait_index].name,
            }),
            "the bound is not satisfied",
            try f.diags.fmt("add `impl {s} for {s}`", .{
                f.symbols.traits[trait_index].name,
                try f.tyName(arg),
            }),
        );
    }

    const tir_index = try f.mono.instantiate(target, resolved);

    return .{ .call_function = .{
        .target = tir_index,
        .args = args,
        .ty = try types.substitute(f.arena, info.ret, resolved),
        .span = c.span,
    } };
}

fn crossesSharedRef(expr: tir.Expr) bool {
    const ty = expr.typeOf();
    if (ty == .ref and !ty.ref.mutable) return true;
    return switch (expr) {
        .field => |x| crossesSharedRef(x.base.*),
        .index => |x| crossesSharedRef(x.base.*),
        .deref => |d| crossesSharedRef(d.operand.*),
        .borrow => |b| crossesSharedRef(b.operand.*),
        else => false,
    };
}

fn requireMutableReceiver(f: *Fn, receiver: tir.Expr, m: ast.MethodCall) Error!void {
    if (!crossesSharedRef(receiver)) return;
    var owned = receiver.typeOf();
    while (owned == .ref) owned = owned.ref.target.*;
    const name = if (rootPlace(f, receiver)) |place| place.name else "this";
    try f.diags.err(
        .immutable_assign,
        m.span,
        try f.diags.fmt("cannot change `{s}` through a shared reference", .{name}),
        try f.diags.fmt("`{s}` only allows reading", .{try f.tyName(receiver.typeOf())}),
        try f.diags.fmt("take `&mut {s}` to change it", .{try f.tyName(owned)}),
    );
}

const VEC_METHODS = [_]struct { name: []const u8, op: tir.VecOp.Op, arity: usize }{
    .{ .name = "push", .op = .push, .arity = 1 },
    .{ .name = "get", .op = .get, .arity = 1 },
    .{ .name = "set", .op = .set, .arity = 2 },
    .{ .name = "len", .op = .len, .arity = 0 },
};

fn lowerVecNew(f: *Fn, m: ast.MethodCall) Error!tir.Expr {
    const bad: tir.Expr = .{ .vec_op = .{ .op = .new, .args = &.{}, .ty = .invalid, .span = m.span } };

    const want = f.expected orelse {
        try f.diags.err(
            .cannot_infer,
            m.span,
            "cannot tell what this `Vec` holds",
            "the element type is unknown here",
            "annotate it, as in `let v: Vec<Int> = Vec.new(a)`",
        );
        return bad;
    };

    if (want != .vec) {
        try f.diags.err(
            .type_mismatch,
            m.span,
            "this is not a `Vec`",
            try f.diags.fmt("expected `{s}`", .{try f.tyName(want)}),
            null,
        );
        return bad;
    }

    if (m.args.len != 1) {
        try f.diags.err(
            .wrong_arg_count,
            m.span,
            "`Vec.new` takes an allocator",
            try f.diags.fmt("expected 1, found {d}", .{m.args.len}),
            null,
        );
        return bad;
    }

    const alloc = try lowerExpr(f, m.args[0]);
    if (!alloc.typeOf().isInvalid() and alloc.typeOf() != .allocator) {
        try f.diags.err(
            .type_mismatch,
            m.args[0].spanOf(),
            "expected an allocator",
            try f.diags.fmt("expected `Allocator`, found `{s}`", .{try f.tyName(alloc.typeOf())}),
            null,
        );
    }

    const args = try f.arena.alloc(tir.Expr, 1);
    args[0] = alloc;

    return .{ .vec_op = .{ .op = .new, .args = args, .ty = want, .span = m.span } };
}

fn lowerVecMethod(f: *Fn, m: ast.MethodCall, receiver: tir.Expr, vec_ty: Type) Error!tir.Expr {
    const elem = vec_ty.vec.elem.*;
    const bad: tir.Expr = .{ .vec_op = .{ .op = .len, .args = &.{}, .ty = .invalid, .span = m.span } };

    const spec = for (VEC_METHODS) |candidate| {
        if (std.mem.eql(u8, candidate.name, m.name)) break candidate;
    } else {
        try f.diags.err(
            .unknown_method,
            m.name_span,
            try f.diags.fmt("no method `{s}` on `{s}`", .{ m.name, try f.tyName(vec_ty) }),
            "not one of push, get, set or len",
            null,
        );
        for (m.args) |arg| _ = try lowerExpr(f, arg);
        return bad;
    };

    if (m.args.len != spec.arity) {
        try f.diags.err(
            .wrong_arg_count,
            m.span,
            try f.diags.fmt("`{s}` takes {d} {s}", .{
                m.name,
                spec.arity,
                if (spec.arity == 1) "argument" else "arguments",
            }),
            try f.diags.fmt("expected {d}, found {d}", .{ spec.arity, m.args.len }),
            null,
        );
        for (m.args) |arg| _ = try lowerExpr(f, arg);
        return bad;
    }

    if (spec.op == .push or spec.op == .set) try requireMutableReceiver(f, receiver, m);

    const wants: [2]Type = switch (spec.op) {
        .push => .{ elem, .void },
        .get => .{ .int, .void },
        .set => .{ .int, elem },
        else => .{ .void, .void },
    };

    var args: std.ArrayList(tir.Expr) = .empty;
    try args.append(f.arena, receiver);

    for (m.args, 0..) |arg, i| {
        const lowered = try lowerWithExpected(f, arg, wants[i]);
        const got = lowered.typeOf();
        if (!got.isInvalid() and !Type.eql(got, wants[i])) {
            try f.diags.err(
                .type_mismatch,
                arg.spanOf(),
                "argument type mismatch",
                try f.diags.fmt("expected `{s}`, found `{s}`", .{ try f.tyName(wants[i]), try f.tyName(got) }),
                null,
            );
        }
        try args.append(f.arena, lowered);
    }

    const owns = types.needsDrop(elem, f.symbols.registry());

    const result: Type = switch (spec.op) {
        .get => if (owns) blk: {
            const ptr = try f.arena.create(Type);
            ptr.* = elem;
            break :blk .{ .ref = .{ .mutable = false, .target = ptr } };
        } else elem,
        .len => .int,
        else => .void,
    };

    const lowered = try args.toOwnedSlice(f.arena);
    try f.hoistList(lowered[1..]);

    return .{ .vec_op = .{
        .op = spec.op,
        .args = lowered,
        .ty = result,
        .span = m.span,
    } };
}

const STRING_METHODS = [_]struct { name: []const u8, op: tir.VecOp.Op, arity: usize, arg: Type, ret: Type }{
    .{ .name = "push", .op = .str_push, .arity = 1, .arg = .str, .ret = .void },
    .{ .name = "push_int", .op = .str_push_int, .arity = 1, .arg = .int, .ret = .void },
    .{ .name = "len", .op = .str_len, .arity = 0, .arg = .void, .ret = .int },
};

fn lowerStringNew(f: *Fn, m: ast.MethodCall) Error!tir.Expr {
    const bad: tir.Expr = .{ .vec_op = .{ .op = .str_new, .args = &.{}, .ty = .invalid, .span = m.span } };

    if (m.args.len != 1) {
        try f.diags.err(
            .wrong_arg_count,
            m.span,
            "`String.new` takes an allocator",
            try f.diags.fmt("expected 1, found {d}", .{m.args.len}),
            null,
        );
        return bad;
    }

    const alloc = try lowerExpr(f, m.args[0]);
    if (!alloc.typeOf().isInvalid() and alloc.typeOf() != .allocator) {
        try f.diags.err(
            .type_mismatch,
            m.args[0].spanOf(),
            "expected an allocator",
            try f.diags.fmt("expected `Allocator`, found `{s}`", .{try f.tyName(alloc.typeOf())}),
            null,
        );
    }

    const args = try f.arena.alloc(tir.Expr, 1);
    args[0] = alloc;
    return .{ .vec_op = .{ .op = .str_new, .args = args, .ty = .string, .span = m.span } };
}

fn lowerStringMethod(f: *Fn, m: ast.MethodCall, receiver: tir.Expr) Error!tir.Expr {
    const bad: tir.Expr = .{ .vec_op = .{ .op = .str_len, .args = &.{}, .ty = .invalid, .span = m.span } };

    const spec = for (STRING_METHODS) |candidate| {
        if (std.mem.eql(u8, candidate.name, m.name)) break candidate;
    } else {
        try f.diags.err(
            .unknown_method,
            m.name_span,
            try f.diags.fmt("no method `{s}` on `String`", .{m.name}),
            "not one of push, push_int or len",
            null,
        );
        for (m.args) |arg| _ = try lowerExpr(f, arg);
        return bad;
    };

    if (m.args.len != spec.arity) {
        try f.diags.err(
            .wrong_arg_count,
            m.span,
            try f.diags.fmt("`{s}` takes {d} {s}", .{
                m.name,
                spec.arity,
                if (spec.arity == 1) "argument" else "arguments",
            }),
            try f.diags.fmt("expected {d}, found {d}", .{ spec.arity, m.args.len }),
            null,
        );
        for (m.args) |arg| _ = try lowerExpr(f, arg);
        return bad;
    }

    if (spec.ret == .void) try requireMutableReceiver(f, receiver, m);

    var args: std.ArrayList(tir.Expr) = .empty;
    try args.append(f.arena, receiver);

    for (m.args) |arg| {
        const lowered = try lowerWithExpected(f, arg, spec.arg);
        const got = lowered.typeOf();
        if (!got.isInvalid() and !Type.eql(got, spec.arg)) {
            try f.diags.err(
                .type_mismatch,
                arg.spanOf(),
                "argument type mismatch",
                try f.diags.fmt("expected `{s}`, found `{s}`", .{ try f.tyName(spec.arg), try f.tyName(got) }),
                null,
            );
        }
        try args.append(f.arena, lowered);
    }

    return .{ .vec_op = .{
        .op = spec.op,
        .args = try args.toOwnedSlice(f.arena),
        .ty = spec.ret,
        .span = m.span,
    } };
}

pub fn lowerMethodCall(f: *Fn, m: ast.MethodCall) Error!tir.Expr {
    if (m.receiver.* == .var_ref) {
        const name = m.receiver.var_ref.name;
        if (f.lookup(name) == null and std.mem.eql(u8, m.name, "new")) {
            if (std.mem.eql(u8, name, "Vec")) return lowerVecNew(f, m);
            if (std.mem.eql(u8, name, "String")) return lowerStringNew(f, m);
        }
    }

    const receiver = try f.hoistOwning(try lowerExpr(f, m.receiver.*));

    {
        var probe = receiver.typeOf();
        while (probe == .ref) probe = probe.ref.target.*;
        if (probe == .vec) return lowerVecMethod(f, m, receiver, probe);
        if (probe == .string) return lowerStringMethod(f, m, receiver);
    }

    var target = receiver.typeOf();
    while (target == .ref) target = target.ref.target.*;

    const bad: tir.Expr = .{ .call_builtin = .{
        .builtin = .print_line,
        .args = &.{},
        .ty = .invalid,
        .span = m.span,
    } };

    if (target.isInvalid()) return bad;

    const found = f.symbols.findImpl(target, m.name) orelse {
        try f.diags.err(
            .unknown_method,
            m.name_span,
            try f.diags.fmt("no method `{s}` on `{s}`", .{ m.name, try f.tyName(target) }),
            "no trait implementation provides it",
            "implement a trait for this type, or check the name",
        );
        for (m.args) |arg| _ = try lowerExpr(f, arg);
        return bad;
    };

    const info = f.symbols.signature(found.fn_index);

    var args: std.ArrayList(tir.Expr) = .empty;

    const self_arg: tir.Expr = if (receiver.typeOf() == .ref) receiver else blk: {
        const ptr = try f.arena.create(Type);
        ptr.* = target;
        break :blk .{ .borrow = .{
            .mutable = false,
            .operand = try f.box(receiver),
            .ty = .{ .ref = .{ .mutable = false, .target = ptr } },
            .span = m.span,
        } };
    };
    try args.append(f.arena, self_arg);

    for (m.args, 0..) |arg, i| {
        const want: ?Type = if (i + 1 < info.params.len) info.params[i + 1] else null;
        try args.append(f.arena, try lowerWithExpected(f, arg, want));
    }

    const lowered = try args.toOwnedSlice(f.arena);
    try f.hoistList(lowered);

    if (lowered.len != info.params.len) {
        try f.diags.err(
            .wrong_arg_count,
            m.span,
            try f.diags.fmt("`{s}` takes {d} {s}", .{
                m.name,
                info.params.len - 1,
                if (info.params.len == 2) "argument" else "arguments",
            }),
            try f.diags.fmt("expected {d}, found {d}", .{ info.params.len - 1, lowered.len - 1 }),
            null,
        );
        return bad;
    }

    for (lowered[1..], info.params[1..]) |arg, want| {
        const got = arg.typeOf();
        if (!got.isInvalid() and !Type.eql(got, want)) {
            try f.diags.err(
                .type_mismatch,
                arg.spanOf(),
                "argument type mismatch",
                try f.diags.fmt("expected `{s}`, found `{s}`", .{ try f.tyName(want), try f.tyName(got) }),
                null,
            );
        }
    }

    const tir_index = f.mono.ast_to_tir[found.fn_index] orelse
        try f.mono.instantiate(found.fn_index, &.{});

    return .{ .call_function = .{
        .target = tir_index,
        .args = lowered,
        .ty = info.ret,
        .span = m.span,
    } };
}

pub fn lowerTry(f: *Fn, t: ast.Try) Error!tir.Expr {
    const operand = try lowerExpr(f, t.operand.*);
    const src = operand.typeOf();

    const bad: tir.Expr = .{ .try_unwrap = .{
        .operand = try f.box(operand),
        .source_enum = 0,
        .ret_enum = 0,
        .ok_variant = 0,
        .err_variant = 1,
        .ty = .invalid,
        .span = t.span,
    } };

    if (src.isInvalid()) return bad;

    if (src != .enumeration or f.ret_ty != .enumeration) {
        try f.diags.err(
            .bad_pattern,
            t.span,
            "`?` needs an enum value and an enum return type",
            try f.diags.fmt("this is `{s}`", .{try f.tyName(src)}),
            "`?` propagates the second variant and unwraps the first",
        );
        return bad;
    }

    const src_tpl = templateOf(f, src.enumeration);
    const ret_tpl = templateOf(f, f.ret_ty.enumeration);
    const same_enum = src.enumeration == f.ret_ty.enumeration;
    const same_template = src_tpl != null and ret_tpl != null and src_tpl.? == ret_tpl.?;

    if (!same_enum and !same_template) {
        try f.diags.err(
            .bad_pattern,
            t.span,
            "`?` needs the same enum as the return type",
            try f.diags.fmt("found `{s}`, function returns `{s}`", .{
                try f.tyName(src),
                try f.tyName(f.ret_ty),
            }),
            null,
        );
        return bad;
    }

    const src_def = f.symbols.enums.items[src.enumeration];
    const ret_def = f.symbols.enums.items[f.ret_ty.enumeration];

    if (src_def.variants.len != 2 or src_def.variants[0].payload.len != 1) {
        try f.diags.err(
            .bad_pattern,
            t.span,
            "`?` needs an enum with two variants where the first carries one value",
            try f.diags.fmt("`{s}` does not have that shape", .{src_def.name}),
            null,
        );
        return bad;
    }

    const src_err = src_def.variants[1].payload;
    const ret_err = ret_def.variants[1].payload;

    if (src_err.len != ret_err.len) {
        try f.diags.err(
            .type_mismatch,
            t.span,
            "the error variants do not match",
            "cannot propagate",
            null,
        );
        return bad;
    }

    for (src_err, ret_err) |a, b| {
        if (!Type.eql(a, b)) {
            try f.diags.err(
                .type_mismatch,
                t.span,
                "the error variants carry different types",
                try f.diags.fmt("`{s}` cannot propagate into `{s}`", .{ src_def.name, ret_def.name }),
                null,
            );
            return bad;
        }
    }

    return .{ .try_unwrap = .{
        .operand = try f.box(operand),
        .source_enum = src.enumeration,
        .ret_enum = f.ret_ty.enumeration,
        .ok_variant = 0,
        .err_variant = 1,
        .ty = src_def.variants[0].payload[0],
        .span = t.span,
    } };
}

pub fn templateOf(f: *Fn, enum_index: u32) ?u32 {
    for (f.symbols.instances.items) |inst| {
        const tpl = f.symbols.templates.items[inst.template];
        if (tpl.enum_def == null) continue;
        if (inst.index == enum_index) return inst.template;
    }
    return null;
}
