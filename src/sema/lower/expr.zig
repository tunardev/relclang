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
const block_mod = @import("block.zig");
const rootPlace = block_mod.rootPlace;
const lowerBlock = block_mod.lowerBlock;
const lowerIf = block_mod.lowerIf;
const literal_mod = @import("literal.zig");
const lowerStructLit = literal_mod.lowerStructLit;
const match_mod = @import("match.zig");
const lowerMatch = match_mod.lowerMatch;
const call_mod = @import("call.zig");
const lowerEnumLit = @import("literal.zig").lowerEnumLit;
const lowerCall = call_mod.lowerCall;
const lowerMethodCall = call_mod.lowerMethodCall;
const lowerTry = call_mod.lowerTry;

pub fn autoDeref(f: *Fn, e: tir.Expr) Error!tir.Expr {
    var current = e;
    while (current.typeOf() == .ref) {
        const target = current.typeOf().ref.target.*;
        const boxed = try f.box(current);
        const span = current.spanOf();
        current = .{ .deref = .{
            .operand = boxed,
            .ty = target,
            .span = span,
        } };
    }
    return current;
}

pub fn resolveLocalType(f: *Fn, expr: ast.TypeExpr) Error!Type {
    return resolve.resolveType(f.arena, f.symbols, expr, f.diags) catch error.OutOfMemory;
}

pub fn lowerExpr(f: *Fn, expr: ast.Expr) Error!tir.Expr {
    switch (expr) {
        .string => |s| return .{ .string_const = .{ .value = s.value, .ty = .str, .span = s.span } },

        .int => |i| {
            const value = parseInt(i.text) catch {
                try f.diags.err(
                    .integer_overflow,
                    i.span,
                    "integer literal is out of range",
                    "does not fit in `Int`",
                    "`Int` holds values from -9223372036854775808 to 9223372036854775807",
                );
                return .{ .int_const = .{ .value = 0, .ty = .invalid, .span = i.span } };
            };
            return .{ .int_const = .{ .value = value, .ty = .int, .span = i.span } };
        },

        .var_ref => |v| {
            if (f.lookup(v.name) == null) {
                if (f.symbols.lookup(v.name)) |symbol| {
                    if (symbol == .variant) {
                        return lowerEnumLit(f, symbol.variant, &.{}, &.{}, v.span);
                    }
                }
            }

            const binding = f.lookup(v.name) orelse {
                try f.diags.err(
                    .unknown_variable,
                    v.span,
                    try f.diags.fmt("cannot find `{s}` in this scope", .{v.name}),
                    "not defined here",
                    null,
                );
                return .{ .local_ref = .{ .slot = 0, .ty = .invalid, .span = v.span } };
            };
            f.locals.items[binding.slot].used = true;
            return .{ .local_ref = .{ .slot = binding.slot, .ty = binding.ty, .span = v.span } };
        },

        .unary => |u| {
            const operand = try lowerExpr(f, u.operand.*);
            const ty = typecheck.unaryResult(u.op, operand.typeOf()) orelse blk: {
                try f.diags.err(
                    .invalid_operand,
                    u.span,
                    try f.diags.fmt("`{s}` cannot be applied to `{s}`", .{
                        u.op.symbol(),
                        try f.tyName(operand.typeOf()),
                    }),
                    "invalid operand",
                    null,
                );
                break :blk Type.invalid;
            };
            if (u.op == .neg and operand == .int_const and ty == .int) {
                const folded = std.math.negate(operand.int_const.value) catch {
                    try f.diags.err(
                        .integer_overflow,
                        u.span,
                        "negated literal is out of range",
                        "does not fit in `Int`",
                        null,
                    );
                    return .{ .int_const = .{ .value = 0, .ty = .invalid, .span = u.span } };
                };
                return .{ .int_const = .{ .value = folded, .ty = .int, .span = u.span } };
            }

            return .{ .unary = .{
                .op = unOpOf(u.op),
                .operand = try f.box(operand),
                .ty = ty,
                .span = u.span,
            } };
        },

        .binary => |b| {
            const lhs = try lowerExpr(f, b.lhs.*);
            const rhs = try lowerExpr(f, b.rhs.*);
            const ty = typecheck.binaryResult(b.op, lhs.typeOf(), rhs.typeOf()) orelse blk: {
                try f.diags.err(
                    .invalid_operand,
                    b.op_span,
                    try f.diags.fmt("`{s}` cannot be applied to `{s}` and `{s}`", .{
                        b.op.symbol(),
                        try f.tyName(lhs.typeOf()),
                        try f.tyName(rhs.typeOf()),
                    }),
                    "invalid operands",
                    if (lhs.typeOf() == .str and rhs.typeOf() == .str)
                        "string concatenation is not supported yet"
                    else
                        null,
                );
                break :blk Type.invalid;
            };
            return .{ .binary = .{
                .op = binOpOf(b.op),
                .lhs = try f.box(lhs),
                .rhs = try f.box(rhs),
                .ty = ty,
                .span = b.span,
            } };
        },

        .call => |c| return lowerCall(f, c),

        .try_expr => |t| return lowerTry(f, t),

        .method_call => |m| return lowerMethodCall(f, m),

        .match => |m| return lowerMatch(f, m),

        .boolean => |b| return .{ .bool_const = .{ .value = b.value, .ty = .bool, .span = b.span } },

        .if_expr => |node| return lowerIf(f, node, true),

        .while_expr => |node| {
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
            const body = try lowerBlock(f, node.body, false);
            return .{ .while_expr = .{
                .cond = try f.box(cond),
                .body = body,
                .span = node.span,
            } };
        },

        .struct_lit => |s| return lowerStructLit(f, s),

        .borrow => |b| {
            const operand = try lowerExpr(f, b.operand.*);
            const target = try f.arena.create(Type);
            target.* = operand.typeOf();

            if (b.mutable) {
                if (rootPlace(f, operand)) |place| {
                    f.locals.items[place.slot].assigned = true;
                    if (!place.is_mut) {
                        try f.diags.err(
                            .immutable_assign,
                            b.span,
                            try f.diags.fmt("cannot borrow `{s}` mutably", .{place.name}),
                            "this binding is not mutable",
                            try f.diags.fmt("declare it with `let mut {s} = ...`", .{place.name}),
                        );
                    }
                } else if (!operand.typeOf().isInvalid()) {
                    try f.diags.err(
                        .not_assignable,
                        b.span,
                        "cannot take a mutable reference to this expression",
                        "not a variable, field or element",
                        null,
                    );
                }
            }

            return .{ .borrow = .{
                .mutable = b.mutable,
                .operand = try f.box(operand),
                .ty = .{ .ref = .{ .mutable = b.mutable, .target = target } },
                .span = b.span,
            } };
        },

        .field => |fa| {
            const raw_base = try lowerExpr(f, fa.base.*);
            const base = try autoDeref(f, raw_base);
            const base_ty = base.typeOf();

            if (base_ty.isInvalid()) {
                return .{ .field = .{ .base = try f.box(base), .strukt = 0, .field = 0, .ty = .invalid, .span = fa.span } };
            }

            if (base_ty != .strukt) {
                try f.diags.err(
                    .unknown_field,
                    fa.field_span,
                    try f.diags.fmt("`{s}` has no fields", .{try f.tyName(base_ty)}),
                    "only structs have fields",
                    null,
                );
                return .{ .field = .{ .base = try f.box(base), .strukt = 0, .field = 0, .ty = .invalid, .span = fa.span } };
            }

            const index = base_ty.strukt;
            const def = f.symbols.structs.items[index];

            const slot = def.fieldIndex(fa.field) orelse {
                try f.diags.err(
                    .unknown_field,
                    fa.field_span,
                    try f.diags.fmt("`{s}` has no field `{s}`", .{ def.name, fa.field }),
                    "unknown field",
                    null,
                );
                return .{ .field = .{ .base = try f.box(base), .strukt = index, .field = 0, .ty = .invalid, .span = fa.span } };
            };

            return .{ .field = .{
                .base = try f.box(base),
                .strukt = index,
                .field = slot,
                .ty = def.fields[slot].ty,
                .span = fa.span,
            } };
        },

        .array_lit => |a| {
            var elems: std.ArrayList(tir.Expr) = .empty;
            for (a.elems) |e| try elems.append(f.arena, try lowerExpr(f, e));
            const lowered = try elems.toOwnedSlice(f.arena);

            if (lowered.len == 0) {
                try f.diags.err(
                    .invalid_operand,
                    a.span,
                    "cannot infer the type of an empty array",
                    "no elements to infer from",
                    "annotate it, as in `let a: [Int; 0] = []`",
                );
                return .{ .array_lit = .{ .elems = lowered, .ty = .invalid, .span = a.span } };
            }

            const first = lowered[0].typeOf();
            for (lowered[1..], 1..) |e, i| {
                const got = e.typeOf();
                if (!got.isInvalid() and !first.isInvalid() and !Type.eql(first, got)) {
                    try f.diags.err(
                        .type_mismatch,
                        a.elems[i].spanOf(),
                        "array elements must all have the same type",
                        try f.diags.fmt("expected `{s}`, found `{s}`", .{ try f.tyName(first), try f.tyName(got) }),
                        null,
                    );
                }
            }

            const elem_ptr = try f.arena.create(Type);
            elem_ptr.* = first;

            return .{ .array_lit = .{
                .elems = lowered,
                .ty = .{ .array = .{ .elem = elem_ptr, .len = lowered.len } },
                .span = a.span,
            } };
        },

        .index => |x| {
            const raw_base = try lowerExpr(f, x.base.*);
            const base = try autoDeref(f, raw_base);
            const idx = try lowerExpr(f, x.index.*);

            const idx_ty = idx.typeOf();
            if (!idx_ty.isInvalid() and idx_ty != .int) {
                try f.diags.err(
                    .type_mismatch,
                    x.index.spanOf(),
                    "an index must be an `Int`",
                    try f.diags.fmt("expected `Int`, found `{s}`", .{try f.tyName(idx_ty)}),
                    null,
                );
            }

            const base_ty = base.typeOf();
            if (base_ty != .array) {
                if (!base_ty.isInvalid()) {
                    try f.diags.err(
                        .not_indexable,
                        x.span,
                        try f.diags.fmt("`{s}` cannot be indexed", .{try f.tyName(base_ty)}),
                        "only arrays can be indexed",
                        null,
                    );
                }
                return .{ .index = .{ .base = try f.box(base), .index = try f.box(idx), .ty = .invalid, .span = x.span } };
            }

            if (idx == .int_const and idx.int_const.ty == .int) {
                const value = idx.int_const.value;
                if (value < 0 or @as(u64, @intCast(value)) >= base_ty.array.len) {
                    try f.diags.err(
                        .not_indexable,
                        x.index.spanOf(),
                        try f.diags.fmt("index {d} is out of bounds", .{value}),
                        try f.diags.fmt("the array has {d} elements", .{base_ty.array.len}),
                        null,
                    );
                }
            }

            return .{ .index = .{
                .base = try f.box(base),
                .index = try f.box(idx),
                .ty = base_ty.array.elem.*,
                .span = x.span,
            } };
        },
    }
}

pub fn lowerWithExpected(f: *Fn, expr: ast.Expr, expected: ?Type) Error!tir.Expr {
    const saved = f.expected;
    f.expected = expected;
    defer f.expected = saved;
    return lowerExpr(f, expr);
}

pub fn parseInt(text: []const u8) !i64 {
    var value: i64 = 0;
    for (text) |ch| {
        if (ch == '_') continue;
        const digit: i64 = ch - '0';
        value = try std.math.add(i64, try std.math.mul(i64, value, 10), digit);
    }
    return value;
}

pub fn binOpOf(op: ast.BinOp) tir.BinOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .rem => .rem,
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .gt => .gt,
        .le => .le,
        .ge => .ge,
        .logical_and => .logical_and,
        .logical_or => .logical_or,
    };
}

pub fn unOpOf(op: ast.UnOp) tir.UnOp {
    return switch (op) {
        .neg => .neg,
        .not => .not,
    };
}

pub fn builtinOf(b: resolve.Builtin) tir.Builtin {
    return switch (b) {
        .println => .print_line,
        .read_line => .read_line,
    };
}
