const std = @import("std");
const source = @import("../../support/source.zig");
const diagnostics = @import("../../support/diagnostics.zig");
const ast = @import("../../syntax/ast.zig");
const types = @import("../types.zig");
const typecheck = @import("../type_rules.zig");
const symbols_mod = @import("../symbols.zig");

const SymbolTable = symbols_mod.SymbolTable;

pub fn resolveType(
    arena: std.mem.Allocator,
    table: *SymbolTable,
    expr: ast.TypeExpr,
    diags: *diagnostics.Diagnostics,
) !types.Type {
    return resolveTypeIn(arena, table, expr, &.{}, diags);
}

pub fn resolveTypeIn(
    arena: std.mem.Allocator,
    table: *SymbolTable,
    expr: ast.TypeExpr,
    type_params: []const ast.TypeParam,
    diags: *diagnostics.Diagnostics,
) error{OutOfMemory}!types.Type {
    switch (expr) {
        .named => |n| {
            for (type_params, 0..) |tp, i| {
                if (std.mem.eql(u8, tp.name, n.name)) return .{ .param = @intCast(i) };
            }
            if (std.mem.eql(u8, n.name, "Vec")) {
                if (n.args.len != 1) {
                    try diags.err(
                        .wrong_arg_count,
                        n.span,
                        "`Vec` takes 1 type argument",
                        try diags.fmt("expected 1, found {d}", .{n.args.len}),
                        "write it as `Vec<Int>`",
                    );
                    return .invalid;
                }
                const elem = try resolveTypeIn(arena, table, n.args[0], type_params, diags);
                const ptr = try arena.create(types.Type);
                ptr.* = elem;
                return .{ .vec = .{ .elem = ptr } };
            }

            if (typecheck.typeFromName(n.name)) |primitive| return primitive;

            if (table.templateIndex(n.name)) |tpl_index| {
                const tpl = table.templates.items[tpl_index];
                if (n.args.len != tpl.type_param_count) {
                    try diags.err(
                        .wrong_arg_count,
                        n.span,
                        try diags.fmt("`{s}` takes {d} type {s}", .{
                            n.name,
                            tpl.type_param_count,
                            if (tpl.type_param_count == 1) "argument" else "arguments",
                        }),
                        try diags.fmt("expected {d}, found {d}", .{ tpl.type_param_count, n.args.len }),
                        null,
                    );
                    return .invalid;
                }

                const args = try arena.alloc(types.Type, n.args.len);
                for (n.args, 0..) |arg, i| {
                    args[i] = try resolveTypeIn(arena, table, arg, type_params, diags);
                }

                return table.instantiate(tpl_index, args) catch error.OutOfMemory;
            }

            if (table.structIndex(n.name)) |index| return .{ .strukt = index };
            if (table.enumIndex(n.name)) |index| return .{ .enumeration = index };

            try diags.err(
                .unknown_struct,
                n.span,
                try diags.fmt("unknown type `{s}`", .{n.name}),
                "not a known type",
                "the built in types are `Int`, `Bool`, `Str`, `String`, `Vec<T>`, `Allocator` and `Void`",
            );
            return .invalid;
        },
        .ref => |r| {
            const target = try resolveTypeIn(arena, table, r.target.*, type_params, diags);
            const ptr = try arena.create(types.Type);
            ptr.* = target;
            return .{ .ref = .{ .mutable = r.mutable, .target = ptr } };
        },
        .array => |a| {
            const elem = try resolveTypeIn(arena, table, a.elem.*, type_params, diags);

            const len = std.fmt.parseInt(u64, a.len_text, 10) catch {
                try diags.err(
                    .integer_overflow,
                    a.len_span,
                    "array length is out of range",
                    "not a valid length",
                    null,
                );
                return .invalid;
            };

            const ptr = try arena.create(types.Type);
            ptr.* = elem;
            return .{ .array = .{ .elem = ptr, .len = len } };
        },
    }
}

pub fn structDepth(
    structs: []const types.StructDef,
    index: u32,
    seen: []bool,
    done: []bool,
) bool {
    if (done[index]) return false;
    if (seen[index]) return true;
    seen[index] = true;

    for (structs[index].fields) |field| {
        var ty = field.ty;
        while (ty == .array) ty = ty.array.elem.*;
        if (ty == .ref) continue;
        if (ty == .strukt and structDepth(structs, ty.strukt, seen, done)) return true;
    }

    seen[index] = false;
    done[index] = true;
    return false;
}
