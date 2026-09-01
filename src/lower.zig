const std = @import("std");
const source = @import("source.zig");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const typecheck = @import("typecheck.zig");
const ast = @import("ast.zig");
const tir = @import("tir.zig");
const types = @import("types.zig");

const Span = source.Span;
const Type = types.Type;

const Error = error{OutOfMemory};

const Binding = struct {
    name: []const u8,
    slot: u32,
    ty: Type,
    depth: u32,
};

const Fn = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    symbols: *const resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
    bindings: std.ArrayList(Binding),
    locals: std.ArrayList(tir.Local),
    depth: u32,

    fn deinit(f: *Fn) void {
        f.bindings.deinit(f.gpa);
    }

    fn lookup(f: *Fn, name: []const u8) ?Binding {
        var i = f.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, f.bindings.items[i].name, name)) return f.bindings.items[i];
        }
        return null;
    }

    fn declaredAtDepth(f: *Fn, name: []const u8) bool {
        for (f.bindings.items) |b| {
            if (b.depth == f.depth and std.mem.eql(u8, b.name, name)) return true;
        }
        return false;
    }

    fn declare(f: *Fn, name: []const u8, ty: Type) Error!u32 {
        const slot: u32 = @intCast(f.locals.items.len);
        try f.locals.append(f.arena, .{ .name = name, .ty = ty, .used = false });
        try f.bindings.append(f.gpa, .{ .name = name, .slot = slot, .ty = ty, .depth = f.depth });
        return slot;
    }

    fn tyName(f: *Fn, ty: Type) Error![]const u8 {
        return f.symbols.typeName(f.diags.arena.allocator(), ty) catch error.OutOfMemory;
    }

    fn box(f: *Fn, e: tir.Expr) Error!*const tir.Expr {
        const ptr = try f.arena.create(tir.Expr);
        ptr.* = e;
        return ptr;
    }
};

pub fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    program: ast.Program,
    symbols: *const resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
) Error!tir.Program {
    var functions: std.ArrayList(tir.Function) = .empty;

    for (program.fns, 0..) |f, index| {
        var ctx: Fn = .{
            .arena = arena,
            .gpa = gpa,
            .symbols = symbols,
            .diags = diags,
            .bindings = .empty,
            .locals = .empty,
            .depth = 0,
        };
        defer ctx.deinit();

        const info = symbols.signature(index);

        for (f.params, 0..) |param, i| {
            if (ctx.declaredAtDepth(param.name)) {
                try diags.err(
                    .duplicate_binding,
                    param.name_span,
                    try diags.fmt("`{s}` is already a parameter", .{param.name}),
                    "duplicate parameter",
                    null,
                );
            }
            _ = try ctx.declare(param.name, info.params[i]);
            ctx.locals.items[i].used = true;
        }

        const param_count: u32 = @intCast(f.params.len);

        var stmts: std.ArrayList(tir.Stmt) = .empty;
        const last = f.body.stmts.len;

        for (f.body.stmts, 0..) |stmt, i| {
            const is_last = i + 1 == last;
            const lowered = try lowerStmt(&ctx, stmt) orelse continue;

            if (is_last and info.ret != .void and lowered == .expr) {
                const ty = lowered.expr.typeOf();
                if (!ty.isInvalid() and !Type.eql(ty, info.ret)) {
                    try diags.err(
                        .missing_return,
                        lowered.expr.spanOf(),
                        "the final expression does not match the return type",
                        try diags.fmt("expected `{s}`, found `{s}`", .{
                            try symbols.typeName(diags.arena.allocator(), info.ret),
                            try symbols.typeName(diags.arena.allocator(), ty),
                        }),
                        null,
                    );
                }
                try stmts.append(arena, .{ .ret_value = lowered.expr });
                continue;
            }

            if (lowered == .expr) {
                const ty = lowered.expr.typeOf();
                if (ty != .void and !ty.isInvalid()) {
                    try diags.err(
                        .unused_value,
                        lowered.expr.spanOf(),
                        try diags.fmt("this `{s}` value is not used", .{try symbols.typeName(diags.arena.allocator(), ty)}),
                        "the value is discarded",
                        "bind it with `let`, or remove it",
                    );
                }
            }

            try stmts.append(arena, lowered);
        }

        if (info.ret != .void) {
            const returns = last > 0 and stmts.items.len > 0 and stmts.items[stmts.items.len - 1] == .ret_value;
            if (!returns) {
                try diags.err(
                    .missing_return,
                    if (f.ret_ty) |t| t.spanOf() else f.name_span,
                    try diags.fmt("`{s}` must end with a `{s}` value", .{
                        f.name,
                        try symbols.typeName(diags.arena.allocator(), info.ret),
                    }),
                    "no value is returned",
                    "the last line of the body is its return value",
                );
            }
        }

        try functions.append(arena, .{
            .name = f.name,
            .is_entry = symbols.entry != null and symbols.entry.? == index,
            .param_count = param_count,
            .ret = info.ret,
            .locals = try ctx.locals.toOwnedSlice(arena),
            .body = .{ .stmts = try stmts.toOwnedSlice(arena) },
            .span = f.span,
        });
    }

    return .{
        .functions = try functions.toOwnedSlice(arena),
        .structs = symbols.structs,
        .enums = symbols.enums,
    };
}

fn lowerStmt(f: *Fn, stmt: ast.Stmt) Error!?tir.Stmt {
    switch (stmt) {
        .expr => |e| return .{ .expr = try lowerExpr(f, e) },
        .let => |l| {
            const init_expr = try lowerExpr(f, l.init);
            var ty = init_expr.typeOf();

            if (l.ty) |ty_expr| {
                const annotated = try resolveLocalType(f, ty_expr);

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

            const slot = try f.declare(l.name, ty);

            return .{ .let = .{
                .slot = slot,
                .init = init_expr,
                .ty = ty,
                .span = l.span,
            } };
        },
    }
}

fn resolveLocalType(f: *Fn, expr: ast.TypeExpr) Error!Type {
    switch (expr) {
        .named => |n| {
            if (typecheck.typeFromName(n.name)) |primitive| return primitive;
            if (f.symbols.structIndex(n.name)) |index| return .{ .strukt = index };
            try f.diags.err(
                .unknown_struct,
                n.span,
                try f.diags.fmt("unknown type `{s}`", .{n.name}),
                "not a known type",
                "the built in types are `Int`, `Str` and `Void`",
            );
            return .invalid;
        },
        .array => |a| {
            const elem = try resolveLocalType(f, a.elem.*);
            const len = std.fmt.parseInt(u64, a.len_text, 10) catch {
                try f.diags.err(.integer_overflow, a.len_span, "array length is out of range", "not a valid length", null);
                return .invalid;
            };
            const ptr = try f.arena.create(Type);
            ptr.* = elem;
            return .{ .array = .{ .elem = ptr, .len = len } };
        },
    }
}

fn lowerStructLit(f: *Fn, s: ast.StructLit) Error!tir.Expr {
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

    const def = f.symbols.structs[index];
    const slots = try f.arena.alloc(tir.Expr, def.fields.len);
    const filled = try f.gpa.alloc(bool, def.fields.len);
    defer f.gpa.free(filled);
    @memset(filled, false);

    for (def.fields, 0..) |field, i| {
        slots[i] = .{ .int_const = .{ .value = 0, .ty = field.ty, .span = s.span } };
    }

    for (s.fields) |init_field| {
        const value = try lowerExpr(f, init_field.value);

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

    return .{ .struct_lit = .{
        .strukt = index,
        .fields = slots,
        .ty = .{ .strukt = index },
        .span = s.span,
    } };
}

fn lowerExpr(f: *Fn, expr: ast.Expr) Error!tir.Expr {
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

        .match => |m| return lowerMatch(f, m),

        .struct_lit => |s| return lowerStructLit(f, s),

        .field => |fa| {
            const base = try lowerExpr(f, fa.base.*);
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
            const def = f.symbols.structs[index];

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
            const base = try lowerExpr(f, x.base.*);
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

fn lowerMatch(f: *Fn, m: ast.Match) Error!tir.Expr {
    const scrutinee = try lowerExpr(f, m.scrutinee.*);
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
            .arms = &.{},
            .ty = .invalid,
            .span = m.span,
        } };
    }

    const enum_index = scrut_ty.enumeration;
    const def = f.symbols.enums[enum_index];

    const covered = try f.gpa.alloc(bool, def.variants.len);
    defer f.gpa.free(covered);
    @memset(covered, false);

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
                            slots[i] = try f.declare(binding.name, payload[i]);
                        }
                    }
                }
            },
        }

        const body = try lowerExpr(f, arm.body);
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
        .arms = try arms.toOwnedSlice(f.arena),
        .ty = result_ty orelse (if (saw_invalid) Type.invalid else Type.void),
        .span = m.span,
    } };
}

fn lowerEnumLit(
    f: *Fn,
    ref: resolve.VariantRef,
    args: []const tir.Expr,
    arg_spans: []const source.Span,
    span: Span,
) Error!tir.Expr {
    const def = f.symbols.enums[ref.enumeration];
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

fn lowerCall(f: *Fn, c: ast.Call) Error!tir.Expr {
    var args: std.ArrayList(tir.Expr) = .empty;
    for (c.args) |arg| try args.append(f.arena, try lowerExpr(f, arg));
    const lowered = try args.toOwnedSlice(f.arena);

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
            const info = f.symbols.signature(target);
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
                .target = target,
                .args = lowered,
                .ty = info.ret,
                .span = c.span,
            } };
        },
    }
}

fn parseInt(text: []const u8) !i64 {
    var value: i64 = 0;
    for (text) |ch| {
        if (ch == '_') continue;
        const digit: i64 = ch - '0';
        value = try std.math.add(i64, try std.math.mul(i64, value, 10), digit);
    }
    return value;
}

fn binOpOf(op: ast.BinOp) tir.BinOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .rem => .rem,
    };
}

fn unOpOf(op: ast.UnOp) tir.UnOp {
    return switch (op) {
        .neg => .neg,
    };
}

fn builtinOf(b: resolve.Builtin) tir.Builtin {
    return switch (b) {
        .println => .print_line,
    };
}

const testing = std.testing;

const Lowered = struct {
    arena: std.heap.ArenaAllocator,
    diags: diagnostics.Diagnostics,
    symbols: resolve.SymbolTable,
    program: tir.Program,

    fn deinit(l: *Lowered) void {
        l.symbols.deinit();
        l.diags.deinit();
        l.arena.deinit();
    }

    fn has(l: Lowered, code: diagnostics.Code) bool {
        for (l.diags.list.items) |item| {
            if (item.code == code) return true;
        }
        return false;
    }
};

fn lowerText(gpa: std.mem.Allocator, text: []const u8) !Lowered {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    var d: diagnostics.Diagnostics = .init(gpa);
    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    const toks = try lexer.tokenize(arena_state.allocator(), file, &d);
    const parsed = try parser.parse(arena_state.allocator(), toks, &d);
    var symbols = try resolve.run(arena_state.allocator(), gpa, parsed, &d);
    const program = try run(arena_state.allocator(), gpa, parsed, &symbols, &d);
    return .{ .arena = arena_state, .diags = d, .symbols = symbols, .program = program };
}

test "lowers println to the print_line builtin" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(\"hi\")\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const f = l.program.functions[0];
    try testing.expect(f.is_entry);

    const call = f.body.stmts[0].expr.call_builtin;
    try testing.expectEqual(tir.Builtin.print_line, call.builtin);
    try testing.expectEqualStrings("hi", call.args[0].string_const.value);
}

test "only main is marked as the entry point" {
    var l = try lowerText(testing.allocator, "fn helper() {\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(!l.program.functions[0].is_entry);
    try testing.expect(l.program.functions[1].is_entry);
}

test "lowers a user function call" {
    var l = try lowerText(testing.allocator, "fn helper() {\n}\nfn main() {\n    helper()\n}\n");
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.program.functions[1].body.stmts[0].expr.call_function.target);
}

test "let allocates a slot and records its type" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x = 10\n    println(x)\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const f = l.program.functions[0];
    try testing.expectEqual(@as(usize, 1), f.locals.len);
    try testing.expectEqualStrings("x", f.locals[0].name);
    try testing.expectEqual(types.Type.int, f.locals[0].ty);
    try testing.expect(f.locals[0].used);

    const decl = f.body.stmts[0].let;
    try testing.expectEqual(@as(u32, 0), decl.slot);
    try testing.expectEqual(@as(i64, 10), decl.init.int_const.value);
}

test "slots increase in declaration order" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = 1\n    let b = 2\n    println(a + b)\n}\n");
    defer l.deinit();

    const f = l.program.functions[0];
    try testing.expectEqual(@as(u32, 0), f.body.stmts[0].let.slot);
    try testing.expectEqual(@as(u32, 1), f.body.stmts[1].let.slot);

    const sum = f.body.stmts[2].expr.call_builtin.args[0].binary;
    try testing.expectEqual(@as(u32, 0), sum.lhs.local_ref.slot);
    try testing.expectEqual(@as(u32, 1), sum.rhs.local_ref.slot);
}

test "an unused local is marked unused" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x = 1\n}\n");
    defer l.deinit();
    try testing.expect(!l.program.functions[0].locals[0].used);
}

test "precedence puts multiplication under addition" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(2 + 3 * 4)\n}\n");
    defer l.deinit();

    const top = l.program.functions[0].body.stmts[0].expr.call_builtin.args[0].binary;
    try testing.expectEqual(tir.BinOp.add, top.op);
    try testing.expectEqual(@as(i64, 2), top.lhs.int_const.value);
    try testing.expectEqual(tir.BinOp.mul, top.rhs.binary.op);
}

test "subtraction is left associative" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(10 - 3 - 2)\n}\n");
    defer l.deinit();

    const top = l.program.functions[0].body.stmts[0].expr.call_builtin.args[0].binary;
    try testing.expectEqual(tir.BinOp.sub, top.op);
    try testing.expectEqual(tir.BinOp.sub, top.lhs.binary.op);
    try testing.expectEqual(@as(i64, 2), top.rhs.int_const.value);
}

test "underscores are stripped from integer literals" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(1_000)\n}\n");
    defer l.deinit();
    try testing.expectEqual(@as(i64, 1000), l.program.functions[0].body.stmts[0].expr.call_builtin.args[0].int_const.value);
}

test "an annotation overrides the inferred type only when it agrees" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x: Int = 10\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    try testing.expectEqual(types.Type.int, l.program.functions[0].locals[0].ty);
}

test "unknown variable reports E0012" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(z)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unknown_variable));
}

test "duplicate binding reports E0011" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x = 1\n    let x = 2\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.duplicate_binding));
}

test "string arithmetic reports E0013" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(\"a\" + \"b\")\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.invalid_operand));
}

test "mixed operands report E0013" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let n = 1\n    println(n + \"x\")\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.invalid_operand));
}

test "an annotation mismatch reports E0008" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x: Str = 10\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "binding a void call reports E0013" {
    var l = try lowerText(testing.allocator, "fn helper() {\n}\nfn main() {\n    let x = helper()\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.invalid_operand));
}

test "an out of range literal reports E0014" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(99999999999999999999)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.integer_overflow));
}

test "the largest int literal is accepted" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(9223372036854775807)\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "unknown function reports E0004" {
    var l = try lowerText(testing.allocator, "fn main() {\n    nope(\"hi\")\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unknown_function));
}

test "a bad operand does not cascade into a second error" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(\"a\" + \"b\")\n}\n");
    defer l.deinit();
    try testing.expectEqual(@as(usize, 1), l.diags.list.items.len);
}

test "spans survive lowering" {
    const text = "fn main() {\n    println(\"hi\")\n}\n";
    var l = try lowerText(testing.allocator, text);
    defer l.deinit();
    const arg = l.program.functions[0].body.stmts[0].expr.call_builtin.args[0].string_const;
    try testing.expectEqualStrings("\"hi\"", text[arg.span.start..arg.span.end]);
}

test "parameters become the first locals" {
    var l = try lowerText(testing.allocator, "fn add(a: Int, b: Int) -> Int {\n    a + b\n}\nfn main() {\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const f = l.program.functions[0];
    try testing.expectEqual(@as(u32, 2), f.param_count);
    try testing.expectEqual(types.Type.int, f.ret);
    try testing.expectEqualStrings("a", f.locals[0].name);
    try testing.expectEqualStrings("b", f.locals[1].name);
}

test "the final expression becomes a return value" {
    var l = try lowerText(testing.allocator, "fn f() -> Int {\n    7\n}\nfn main() {\n}\n");
    defer l.deinit();

    const stmts = l.program.functions[0].body.stmts;
    try testing.expectEqual(@as(i64, 7), stmts[stmts.len - 1].ret_value.int_const.value);
}

test "a void function has no return value statement" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(\"hi\")\n}\n");
    defer l.deinit();
    try testing.expect(l.program.functions[0].body.stmts[0] == .expr);
    try testing.expectEqual(types.Type.void, l.program.functions[0].ret);
}

test "a call takes its type from the signature" {
    var l = try lowerText(testing.allocator, "fn f() -> Int {\n    1\n}\nfn main() {\n    println(f())\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    const call = l.program.functions[1].body.stmts[0].expr.call_builtin.args[0].call_function;
    try testing.expectEqual(types.Type.int, call.ty);
}

test "a missing return value reports E0016" {
    var l = try lowerText(testing.allocator, "fn f() -> Int {\n    println(\"x\")\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.missing_return));
}

test "an empty body for a returning function reports E0016" {
    var l = try lowerText(testing.allocator, "fn f() -> Int {\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.missing_return));
}

test "an unused value reports E0015" {
    var l = try lowerText(testing.allocator, "fn main() {\n    1 + 2\n    println(\"x\")\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unused_value));
}

test "wrong argument count to a user function reports E0007" {
    var l = try lowerText(testing.allocator, "fn add(a: Int, b: Int) -> Int {\n    a + b\n}\nfn main() {\n    println(add(1))\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.wrong_arg_count));
}

test "wrong argument type to a user function reports E0008" {
    var l = try lowerText(testing.allocator, "fn add(a: Int, b: Int) -> Int {\n    a + b\n}\nfn main() {\n    println(add(1, \"x\"))\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "a duplicate parameter reports E0011" {
    var l = try lowerText(testing.allocator, "fn f(a: Int, a: Int) -> Int {\n    a\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.duplicate_binding));
}

test "a str parameter round trips" {
    var l = try lowerText(testing.allocator, "fn greet(name: Str) {\n    println(name)\n}\nfn main() {\n    greet(\"hi\")\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    try testing.expectEqual(types.Type.str, l.program.functions[0].locals[0].ty);
}

test "a struct literal fills fields in declaration order" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n    y: Int\n}\nfn main() {\n    let p = P { y: 2, x: 1 }\n    println(p.x)\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const lit = l.program.functions[0].body.stmts[0].let.init.struct_lit;
    try testing.expectEqual(@as(i64, 1), lit.fields[0].int_const.value);
    try testing.expectEqual(@as(i64, 2), lit.fields[1].int_const.value);
}

test "field access resolves to a slot index and type" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n    y: Str\n}\nfn main() {\n    let p = P { x: 1, y: \"a\" }\n    println(p.y)\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const access = l.program.functions[0].body.stmts[1].expr.call_builtin.args[0].field;
    try testing.expectEqual(@as(u32, 1), access.field);
    try testing.expect(types.Type.eql(.str, access.ty));
}

test "an array literal infers its element type and length" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = [1, 2, 3]\n    println(a[0])\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const ty = l.program.functions[0].locals[0].ty;
    try testing.expect(ty == .array);
    try testing.expectEqual(@as(u64, 3), ty.array.len);
    try testing.expect(types.Type.eql(.int, ty.array.elem.*));
}

test "indexing yields the element type" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = [\"x\"]\n    println(a[0])\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    const idx = l.program.functions[0].body.stmts[1].expr.call_builtin.args[0].index;
    try testing.expect(types.Type.eql(.str, idx.ty));
}

test "an unknown field reports E0019" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n}\nfn main() {\n    let p = P { x: 1 }\n    println(p.z)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unknown_field));
}

test "a missing field reports E0020" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n    y: Int\n}\nfn main() {\n    let p = P { x: 1 }\n    println(p.x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.missing_field));
}

test "a duplicated field in a literal reports E0011" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n}\nfn main() {\n    let p = P { x: 1, x: 2 }\n    println(p.x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.duplicate_binding));
}

test "a constant out of bounds index reports E0022" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = [1, 2]\n    println(a[5])\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.not_indexable));
}

test "a negative constant index reports E0022" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = [1, 2]\n    println(a[-1])\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.not_indexable));
}

test "indexing a non array reports E0022" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let n = 3\n    println(n[0])\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.not_indexable));
}

test "a non int index reports E0008" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = [1]\n    println(a[\"x\"])\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "mixed array element types report E0008" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = [1, \"two\"]\n    println(a[0])\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "an empty array literal cannot be inferred" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = []\n    println(a[0])\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.invalid_operand));
}

test "printing a struct reports a type mismatch" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n}\nfn main() {\n    let p = P { x: 1 }\n    println(p)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "nested arrays type correctly" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let g = [[1, 2], [3, 4]]\n    println(g[0][1])\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    const ty = l.program.functions[0].locals[0].ty;
    try testing.expectEqual(@as(u64, 2), ty.array.len);
    try testing.expectEqual(@as(u64, 2), ty.array.elem.array.len);
}

test "a unit variant lowers to an enum literal" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn main() {\n    let c = Red\n    println(1)\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const lit = l.program.functions[0].body.stmts[0].let.init.enum_lit;
    try testing.expectEqual(@as(u32, 0), lit.variant);
    try testing.expectEqual(@as(usize, 0), lit.payload.len);
}

test "a payload variant carries its arguments" {
    var l = try lowerText(testing.allocator, "enum S {\n    Pair(Int, Int)\n}\nfn main() {\n    let s = Pair(1, 2)\n    println(1)\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const lit = l.program.functions[0].body.stmts[0].let.init.enum_lit;
    try testing.expectEqual(@as(usize, 2), lit.payload.len);
    try testing.expectEqual(@as(i64, 2), lit.payload[1].int_const.value);
}

test "match binds payload values to local slots" {
    var l = try lowerText(testing.allocator, "enum S {\n    Pair(Int, Int)\n}\nfn f(s: S) -> Int {\n    match s {\n        Pair(a, b) => a + b\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const m = l.program.functions[0].body.stmts[0].ret_value.match;
    try testing.expectEqual(@as(usize, 1), m.arms.len);
    try testing.expectEqual(@as(usize, 2), m.arms[0].bindings.len);
    try testing.expect(types.Type.eql(.int, m.ty));
}

test "an exhaustive match needs no wildcard" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn f(c: C) -> Int {\n    match c {\n        Red => 1\n        Green => 2\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "a missing variant reports E0023" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn f(c: C) -> Int {\n    match c {\n        Red => 1\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.non_exhaustive));
}

test "a wildcard makes a match exhaustive" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn f(c: C) -> Int {\n    match c {\n        Red => 1\n        _ => 0\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "a repeated variant reports E0024" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn f(c: C) -> Int {\n    match c {\n        Red => 1\n        Red => 2\n        Green => 3\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unreachable_arm));
}

test "an arm after a wildcard reports E0024" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn f(c: C) -> Int {\n    match c {\n        _ => 0\n        Red => 1\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unreachable_arm));
}

test "an unknown variant in a pattern reports E0025" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n}\nfn f(c: C) -> Int {\n    match c {\n        Blue => 1\n        _ => 0\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.bad_pattern));
}

test "the wrong binding count reports E0025 without cascading" {
    var l = try lowerText(testing.allocator, "enum S {\n    Pair(Int, Int)\n}\nfn f(s: S) -> Int {\n    match s {\n        Pair(a) => a\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.bad_pattern));
    try testing.expect(!l.has(.unknown_variable));
    try testing.expectEqual(@as(usize, 1), l.diags.list.items.len);
}

test "arms of different types report E0008" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn f(c: C) -> Int {\n    match c {\n        Red => 1\n        Green => \"two\"\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "matching a non enum reports E0025" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let n = 3\n    println(match n {\n        _ => 1\n    })\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.bad_pattern));
}

test "a wrong payload arity reports E0007" {
    var l = try lowerText(testing.allocator, "enum S {\n    One(Int)\n}\nfn main() {\n    let s = One(1, 2)\n    println(1)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.wrong_arg_count));
}

test "a wrong payload type reports E0008" {
    var l = try lowerText(testing.allocator, "enum S {\n    One(Int)\n}\nfn main() {\n    let s = One(\"x\")\n    println(1)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "pattern bindings do not leak out of their arm" {
    var l = try lowerText(testing.allocator, "enum S {\n    One(Int)\n}\nfn f(s: S) -> Int {\n    match s {\n        One(v) => v\n    }\n}\nfn main() {\n    println(v)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unknown_variable));
}

test "a match used as a statement is void" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn main() {\n    let c = Red\n    match c {\n        Red => println(\"r\")\n        Green => println(\"g\")\n    }\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    try testing.expect(types.Type.eql(.void, l.program.functions[0].body.stmts[1].expr.match.ty));
}
