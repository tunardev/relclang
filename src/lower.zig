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

const Place = struct {
    slot: u32,
    is_mut: bool,
    name: []const u8,
};

const Instance = struct {
    ast_index: usize,
    args: []const Type,
    tir_index: usize,
};

const Job = struct {
    ast_index: usize,
    args: []const Type,
    tir_index: usize,
};

const Mono = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    symbols: *resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
    program: ast.Program,
    functions: std.ArrayList(tir.Function),
    ast_to_tir: []?usize,
    instances: std.ArrayList(Instance),
    pending: std.ArrayList(Job),

    fn find(m: *Mono, ast_index: usize, args: []const Type) ?usize {
        outer: for (m.instances.items) |inst| {
            if (inst.ast_index != ast_index) continue;
            if (inst.args.len != args.len) continue;
            for (inst.args, args) |a, b| {
                if (!Type.eql(a, b)) continue :outer;
            }
            return inst.tir_index;
        }
        return null;
    }

    fn instantiate(m: *Mono, ast_index: usize, args: []const Type) Error!usize {
        if (m.find(ast_index, args)) |index| return index;

        const tir_index = m.functions.items.len;
        try m.functions.append(m.arena, undefined);

        const owned = try m.arena.dupe(Type, args);
        try m.instances.append(m.gpa, .{
            .ast_index = ast_index,
            .args = owned,
            .tir_index = tir_index,
        });
        try m.pending.append(m.gpa, .{
            .ast_index = ast_index,
            .args = owned,
            .tir_index = tir_index,
        });

        return tir_index;
    }
};

const Fn = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    symbols: *resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
    mono: *Mono,
    ret_ty: Type,
    type_args: []const Type,
    expected: ?Type,
    bindings: std.ArrayList(Binding),
    locals: std.ArrayList(tir.Local),
    depth: u32,

    fn subst(f: *Fn, ty: Type) Error!Type {
        if (f.type_args.len == 0) return ty;
        return types.substitute(f.arena, ty, f.type_args);
    }

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
        return f.declareMut(name, ty, false);
    }

    fn declareMut(f: *Fn, name: []const u8, ty: Type, is_mut: bool) Error!u32 {
        const slot: u32 = @intCast(f.locals.items.len);
        try f.locals.append(f.arena, .{
            .name = name,
            .ty = ty,
            .used = false,
            .is_mut = is_mut,
            .assigned = false,
        });
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
    symbols: *resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
) Error!tir.Program {
    const ast_to_tir = try arena.alloc(?usize, symbols.all_fns.len);
    @memset(ast_to_tir, null);

    var mono: Mono = .{
        .arena = arena,
        .gpa = gpa,
        .symbols = symbols,
        .diags = diags,
        .program = program,
        .functions = .empty,
        .ast_to_tir = ast_to_tir,
        .instances = .empty,
        .pending = .empty,
    };
    defer mono.instances.deinit(gpa);
    defer mono.pending.deinit(gpa);

    for (symbols.all_fns, 0..) |_, index| {
        if (symbols.signature(index).isGeneric()) continue;
        ast_to_tir[index] = mono.functions.items.len;
        try mono.functions.append(arena, undefined);
    }

    for (symbols.all_fns, 0..) |_, index| {
        if (ast_to_tir[index]) |tir_index| {
            const lowered = try lowerFunction(&mono, index, &.{}, tir_index);
            mono.functions.items[tir_index] = lowered;
        }
    }

    while (mono.pending.pop()) |job| {
        const lowered = try lowerFunction(&mono, job.ast_index, job.args, job.tir_index);
        mono.functions.items[job.tir_index] = lowered;
    }

    return .{
        .functions = try mono.functions.toOwnedSlice(arena),
        .structs = symbols.structs.items,
        .enums = symbols.enums.items,
    };
}

fn lowerFunction(
    mono: *Mono,
    index: usize,
    type_args: []const Type,
    tir_index: usize,
) Error!tir.Function {
    const arena = mono.arena;
    const gpa = mono.gpa;
    const symbols = mono.symbols;
    const diags = mono.diags;
    _ = tir_index;

    {
        const f = symbols.all_fns[index];
        var ctx: Fn = .{
            .arena = arena,
            .gpa = gpa,
            .symbols = symbols,
            .diags = diags,
            .mono = mono,
            .ret_ty = .void,
            .type_args = type_args,
            .expected = null,
            .bindings = .empty,
            .locals = .empty,
            .depth = 0,
        };
        defer ctx.deinit();

        const raw = symbols.signature(index);
        const info: resolve.FnInfo = .{
            .name = raw.name,
            .params = blk: {
                const out = try arena.alloc(Type, raw.params.len);
                for (raw.params, 0..) |p, i| out[i] = try types.substitute(arena, p, type_args);
                break :blk out;
            },
            .ret = try types.substitute(arena, raw.ret, type_args),
            .type_param_count = 0,
        };

        var slot_offset: usize = 0;
        if (f.has_self) {
            _ = try ctx.declareMut("self", info.params[0], false);
            ctx.locals.items[0].used = true;
            slot_offset = 1;
        }

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
            _ = try ctx.declareMut(param.name, info.params[i + slot_offset], false);
            ctx.locals.items[i + slot_offset].used = true;
        }

        const param_count: u32 = @intCast(f.params.len + slot_offset);
        ctx.ret_ty = info.ret;
        ctx.expected = if (info.ret == .void) null else info.ret;

        const body = try lowerBlock(&ctx, f.body, info.ret != .void);

        if (info.ret != .void) {
            if (body.result) |result| {
                const ty = result.typeOf();
                if (!ty.isInvalid() and !Type.eql(ty, info.ret)) {
                    try diags.err(
                        .missing_return,
                        result.spanOf(),
                        "the final expression does not match the return type",
                        try diags.fmt("expected `{s}`, found `{s}`", .{
                            try symbols.typeName(diags.arena.allocator(), info.ret),
                            try symbols.typeName(diags.arena.allocator(), ty),
                        }),
                        null,
                    );
                }
            } else {
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

        return .{
            .name = try instanceName(arena, f.name, type_args, symbols),
            .is_entry = symbols.entry != null and symbols.entry.? == index,
            .param_count = param_count,
            .ret = info.ret,
            .locals = try ctx.locals.toOwnedSlice(arena),
            .body = body,
            .span = f.span,
        };
    }
}

fn instanceName(
    arena: std.mem.Allocator,
    name: []const u8,
    args: []const Type,
    symbols: *resolve.SymbolTable,
) Error![]const u8 {
    if (args.len == 0) return name;

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, name);
    for (args) |arg| {
        try out.append(arena, '_');
        const text = symbols.typeName(arena, arg) catch return error.OutOfMemory;
        for (text) |ch| {
            try out.append(arena, switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9' => ch,
                else => '_',
            });
        }
    }
    return out.toOwnedSlice(arena);
}

fn rootPlace(f: *Fn, expr: tir.Expr) ?Place {
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

fn derefPlace(f: *Fn, expr: tir.Expr) ?Place {
    const ty = expr.typeOf();
    if (ty != .ref) return rootPlace(f, expr);

    if (rootPlace(f, expr)) |place| {
        return .{ .slot = place.slot, .is_mut = ty.ref.mutable, .name = place.name };
    }
    return null;
}

fn lowerAssign(f: *Fn, a: ast.Assign) Error!?tir.Stmt {
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

fn lowerBlock(f: *Fn, block: ast.Block, wants_value: bool) Error!tir.Block {
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
        const lowered = try lowerStmt(f, stmt, is_last and wants_value) orelse continue;

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

fn lowerIf(f: *Fn, node: ast.If, wants_value: bool) Error!tir.Expr {
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

fn lowerStmt(f: *Fn, stmt: ast.Stmt, wants_value: bool) Error!?tir.Stmt {
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

            return .{ .let = .{
                .slot = slot,
                .init = init_expr,
                .ty = ty,
                .span = l.span,
            } };
        },
    }
}

fn autoDeref(f: *Fn, e: tir.Expr) Error!tir.Expr {
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

fn resolveLocalType(f: *Fn, expr: ast.TypeExpr) Error!Type {
    return resolve.resolveType(f.arena, f.symbols, expr, f.diags) catch error.OutOfMemory;
}

fn lowerStructLit(f: *Fn, s: ast.StructLit) Error!tir.Expr {
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

fn lowerGenericStructLit(f: *Fn, s: ast.StructLit, tpl_index: u32) Error!tir.Expr {
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
                } else {
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
    const def = f.symbols.enums.items[enum_index];

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
                            slots[i] = try f.declare(binding.name, payload[i]);
                        }
                    }
                }
            },
        }

        const body = try lowerWithExpected(f, arm.body, arm_expected);
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

fn lowerWithExpected(f: *Fn, expr: ast.Expr, expected: ?Type) Error!tir.Expr {
    const saved = f.expected;
    f.expected = expected;
    defer f.expected = saved;
    return lowerExpr(f, expr);
}

fn lowerMethodCall(f: *Fn, m: ast.MethodCall) Error!tir.Expr {
    const receiver = try lowerExpr(f, m.receiver.*);
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

fn lowerTry(f: *Fn, t: ast.Try) Error!tir.Expr {
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

    if (src_tpl == null or ret_tpl == null or src_tpl.? != ret_tpl.?) {
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

fn templateOf(f: *Fn, enum_index: u32) ?u32 {
    for (f.symbols.instances.items) |inst| {
        const tpl = f.symbols.templates.items[inst.template];
        if (tpl.enum_def == null) continue;
        if (inst.index == enum_index) return inst.template;
    }
    return null;
}

fn lowerCall(f: *Fn, c: ast.Call) Error!tir.Expr {
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

fn lowerGenericCall(
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

fn unOpOf(op: ast.UnOp) tir.UnOp {
    return switch (op) {
        .neg => .neg,
        .not => .not,
    };
}

fn builtinOf(b: resolve.Builtin) tir.Builtin {
    return switch (b) {
        .println => .print_line,
    };
}
