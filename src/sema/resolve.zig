const std = @import("std");
const source = @import("../support/source.zig");
const diagnostics = @import("../support/diagnostics.zig");
const lexer = @import("../syntax/lexer.zig");
const parser = @import("../syntax/parser.zig");
const ast = @import("../syntax/ast.zig");
const types = @import("types.zig");
const typecheck = @import("type_rules.zig");

const symbols_mod = @import("symbols.zig");

pub const Builtin = symbols_mod.Builtin;
pub const VariantRef = symbols_mod.VariantRef;
pub const Symbol = symbols_mod.Symbol;
pub const FnInfo = symbols_mod.FnInfo;
pub const Template = symbols_mod.Template;
pub const TraitInfo = symbols_mod.TraitInfo;
pub const ImplInfo = symbols_mod.ImplInfo;
pub const TypeInstance = symbols_mod.TypeInstance;
pub const SymbolTable = symbols_mod.SymbolTable;

const entry_name = "main";

const type_expr = @import("resolve_impl/type_expr.zig");

pub const resolveType = type_expr.resolveType;
const resolveTypeIn = type_expr.resolveTypeIn;
const structDepth = type_expr.structDepth;

pub fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    program: ast.Program,
    diags: *diagnostics.Diagnostics,
) !SymbolTable {
    var table: SymbolTable = .{
        .gpa = gpa,
        .arena = arena,
        .map = .empty,
        .entry = null,
        .fns = &.{},
        .structs = .empty,
        .struct_map = .empty,
        .enums = .empty,
        .enum_map = .empty,
        .templates = .empty,
        .template_map = .empty,
        .instances = .empty,
        .traits = &.{},
        .trait_map = .empty,
        .impls = &.{},
        .all_fns = &.{},
        .bounds = &.{},
    };
    errdefer table.deinit();

    {
        var trait_list: std.ArrayList(TraitInfo) = .empty;
        for (program.traits, 0..) |decl, i| {
            if (table.trait_map.get(decl.name) != null) {
                try diags.err(
                    .duplicate_function,
                    decl.name_span,
                    try diags.fmt("`{s}` is already defined", .{decl.name}),
                    "duplicate trait",
                    null,
                );
                continue;
            }
            try table.trait_map.put(gpa, decl.name, @intCast(i));

            const names = try arena.alloc([]const u8, decl.methods.len);
            for (decl.methods, 0..) |m, j| names[j] = m.name;
            try trait_list.append(arena, .{ .name = decl.name, .methods = names });
        }
        table.traits = try trait_list.toOwnedSlice(arena);
    }

    for (program.enums) |decl| {
        if (decl.type_params.len == 0) continue;
        if (table.template_map.get(decl.name) != null) continue;
        try table.template_map.put(gpa, decl.name, @intCast(table.templates.items.len));
        try table.templates.append(arena, .{
            .name = decl.name,
            .type_param_count = @intCast(decl.type_params.len),
            .struct_def = null,
            .enum_def = null,
        });
    }

    for (program.structs) |decl| {
        if (decl.type_params.len == 0) continue;
        if (table.template_map.get(decl.name) != null) continue;
        try table.template_map.put(gpa, decl.name, @intCast(table.templates.items.len));
        try table.templates.append(arena, .{
            .name = decl.name,
            .type_param_count = @intCast(decl.type_params.len),
            .struct_def = .{ .name = decl.name, .fields = &.{} },
            .enum_def = null,
        });
    }

    for (program.enums, 0..) |decl, index| {
        if (decl.type_params.len > 0) continue;
        if (table.enum_map.get(decl.name) != null or table.struct_map.get(decl.name) != null) {
            try diags.err(
                .duplicate_function,
                decl.name_span,
                try diags.fmt("`{s}` is already defined", .{decl.name}),
                "duplicate type",
                null,
            );
            continue;
        }
        try table.enum_map.put(gpa, decl.name, @intCast(table.enums.items.len));
        try table.enums.append(arena, .{ .name = decl.name, .variants = &.{} });
        _ = index;
    }

    for (program.structs, 0..) |decl, index| {
        if (decl.type_params.len > 0) continue;
        if (table.struct_map.get(decl.name) != null) {
            try diags.err(
                .duplicate_function,
                decl.name_span,
                try diags.fmt("`{s}` is already defined", .{decl.name}),
                "duplicate struct",
                null,
            );
            continue;
        }
        try table.struct_map.put(gpa, decl.name, @intCast(table.structs.items.len));
        try table.structs.append(arena, .{ .name = decl.name, .fields = &.{} });
        _ = index;
    }

    for (program.enums) |decl| {
        var variants: std.ArrayList(types.VariantDef) = .empty;
        for (decl.variants) |variant| {
            var payload: std.ArrayList(types.Type) = .empty;
            for (variant.payload) |ty_expr| {
                const payload_ty = try resolveTypeIn(arena, &table, ty_expr, decl.type_params, diags);

                if (types.hasReference(payload_ty)) {
                    try diags.err(
                        .reference_field,
                        ty_expr.spanOf(),
                        try diags.fmt("an enum cannot store `{s}`", .{
                            try types.nameOf(arena, table.registry(), payload_ty),
                        }),
                        "a reference has no way to say how long it stays valid",
                        "store the value itself, or pass the reference as an argument",
                    );
                }

                try payload.append(arena, payload_ty);
            }
            try variants.append(arena, .{
                .name = variant.name,
                .payload = try payload.toOwnedSlice(arena),
            });
        }
        const built = try variants.toOwnedSlice(arena);

        if (decl.type_params.len > 0) {
            const tpl = table.template_map.get(decl.name).?;
            table.templates.items[tpl].enum_def = .{ .name = decl.name, .variants = built };
        } else if (table.enum_map.get(decl.name)) |index| {
            table.enums.items[index] = .{ .name = decl.name, .variants = built };
        }
    }

    for (program.enums) |decl| {
        const is_template = decl.type_params.len > 0;
        const owner: u32 = if (is_template)
            table.template_map.get(decl.name).?
        else
            table.enum_map.get(decl.name) orelse continue;

        for (decl.variants, 0..) |variant, vi| {
            if (table.map.get(variant.name) != null) {
                try diags.err(
                    .duplicate_function,
                    variant.name_span,
                    try diags.fmt("`{s}` is already defined", .{variant.name}),
                    "variant names share one namespace with functions",
                    null,
                );
                continue;
            }
            try table.map.put(gpa, variant.name, .{ .variant = .{
                .enumeration = owner,
                .variant = @intCast(vi),
                .from_template = is_template,
            } });
        }
    }

    for (program.structs) |decl| {
        var fields: std.ArrayList(types.Field) = .empty;
        for (decl.fields) |field| {
            for (fields.items) |existing| {
                if (std.mem.eql(u8, existing.name, field.name)) {
                    try diags.err(
                        .duplicate_binding,
                        field.name_span,
                        try diags.fmt("field `{s}` is already declared", .{field.name}),
                        "duplicate field",
                        null,
                    );
                    break;
                }
            }
            const field_ty = try resolveTypeIn(arena, &table, field.ty, decl.type_params, diags);

            if (types.hasReference(field_ty)) {
                try diags.err(
                    .reference_field,
                    field.ty.spanOf(),
                    try diags.fmt("a struct cannot store `{s}`", .{
                        try types.nameOf(arena, table.registry(), field_ty),
                    }),
                    "a reference has no way to say how long it stays valid",
                    "store the value itself, or pass the reference as an argument",
                );
            }

            try fields.append(arena, .{
                .name = field.name,
                .ty = field_ty,
                .span_name = field.name_span.start,
            });
        }
        const built = try fields.toOwnedSlice(arena);

        if (decl.type_params.len > 0) {
            const tpl = table.template_map.get(decl.name).?;
            table.templates.items[tpl].struct_def = .{ .name = decl.name, .fields = built };
        } else if (table.struct_map.get(decl.name)) |index| {
            table.structs.items[index] = .{ .name = decl.name, .fields = built };
        }
    }

    if (table.structs.items.len > 0) {
        const seen = try arena.alloc(bool, table.structs.items.len);
        const done = try arena.alloc(bool, table.structs.items.len);
        @memset(seen, false);
        @memset(done, false);

        for (table.structs.items, 0..) |_, i| {
            if (i >= program.structs.len) break;
            if (structDepth(table.structs.items, @intCast(i), seen, done)) {
                try diags.err(
                    .recursive_struct,
                    program.structs[i].name_span,
                    try diags.fmt("`{s}` contains itself", .{table.structs.items[i].name}),
                    "this struct would have infinite size",
                    "store it behind a reference once references exist",
                );
                @memset(seen, false);
            }
        }
    }

    inline for (@typeInfo(Builtin).@"enum".fields) |field| {
        try table.map.put(gpa, field.name, .{ .builtin = @field(Builtin, field.name) });
    }

    var combined: std.ArrayList(ast.Fn) = .empty;
    try combined.appendSlice(arena, program.fns);

    var impl_targets: std.ArrayList(types.Type) = .empty;
    var impl_list: std.ArrayList(ImplInfo) = .empty;

    for (program.impls, 0..) |decl, impl_i| {
        const target = try resolveType(arena, &table, decl.target, diags);

        const target_label = switch (decl.target) {
            .named => |n| n.name,
            else => try std.fmt.allocPrint(arena, "impl{d}", .{impl_i}),
        };

        const trait_index = table.trait_map.get(decl.trait_name) orelse {
            try diags.err(
                .unknown_trait,
                decl.trait_span,
                try diags.fmt("unknown trait `{s}`", .{decl.trait_name}),
                "not defined anywhere",
                null,
            );
            continue;
        };

        const trait = table.traits[trait_index];
        const slots = try arena.alloc(usize, trait.methods.len);
        @memset(slots, std.math.maxInt(usize));

        for (decl.methods) |m| {
            var matched = false;
            for (trait.methods, 0..) |name, i| {
                if (!std.mem.eql(u8, name, m.name)) continue;
                slots[i] = combined.items.len;
                matched = true;
                break;
            }

            if (!matched) {
                try diags.err(
                    .unknown_method,
                    m.name_span,
                    try diags.fmt("`{s}` is not a method of `{s}`", .{ m.name, trait.name }),
                    "not declared by the trait",
                    null,
                );
            }

            var renamed = m;
            renamed.name = try std.fmt.allocPrint(arena, "{s}_{s}", .{ target_label, m.name });
            try combined.append(arena, renamed);
            try impl_targets.append(arena, target);
        }

        for (trait.methods, 0..) |name, i| {
            if (slots[i] != std.math.maxInt(usize)) continue;
            try diags.err(
                .missing_impl,
                decl.span,
                try diags.fmt("missing method `{s}`", .{name}),
                try diags.fmt("`{s}` requires it", .{trait.name}),
                null,
            );
        }

        try impl_list.append(arena, .{
            .trait_index = trait_index,
            .target = target,
            .methods = slots,
        });
    }

    table.impls = try impl_list.toOwnedSlice(arena);
    table.all_fns = try combined.toOwnedSlice(arena);

    var infos: std.ArrayList(FnInfo) = .empty;
    var bound_list: std.ArrayList([]const u32) = .empty;

    for (table.all_fns, 0..) |f, fi| {
        var params: std.ArrayList(types.Type) = .empty;

        if (f.has_self) {
            const target: types.Type = if (fi >= program.fns.len)
                impl_targets.items[fi - program.fns.len]
            else blk: {
                try diags.err(
                    .bad_signature,
                    f.name_span,
                    "`self` is only allowed in an `impl` method",
                    "this function is not inside an `impl`",
                    "write `impl Trait for Type { fn ... }` to use `self`",
                );
                break :blk .invalid;
            };
            const ptr = try arena.create(types.Type);
            ptr.* = target;
            try params.append(arena, .{ .ref = .{ .mutable = false, .target = ptr } });
        }

        for (f.params) |param| {
            try params.append(arena, try resolveTypeIn(arena, &table, param.ty, f.type_params, diags));
        }

        const tp_bounds = try arena.alloc(u32, f.type_params.len);
        for (f.type_params, 0..) |tp, ti| {
            tp_bounds[ti] = std.math.maxInt(u32);
            for (tp.bounds) |b| {
                if (table.trait_map.get(b.name)) |ix| {
                    tp_bounds[ti] = ix;
                } else {
                    try diags.err(
                        .unknown_trait,
                        b.span,
                        try diags.fmt("unknown trait `{s}`", .{b.name}),
                        "not defined anywhere",
                        null,
                    );
                }
            }
        }
        try bound_list.append(arena, tp_bounds);

        const ret: types.Type = if (f.ret_ty) |ty_expr|
            try resolveTypeIn(arena, &table, ty_expr, f.type_params, diags)
        else
            .void;

        try infos.append(arena, .{
            .name = f.name,
            .params = try params.toOwnedSlice(arena),
            .ret = ret,
            .type_param_count = @intCast(f.type_params.len),
        });
    }

    table.fns = try infos.toOwnedSlice(arena);
    table.bounds = try bound_list.toOwnedSlice(arena);

    for (program.fns, 0..) |f, index| {
        if (table.map.get(f.name)) |existing| {
            const message = switch (existing) {
                .builtin => "a builtin with this name already exists",
                .function => "this function is already defined",
                .variant => "an enum variant already has this name",
            };
            try diags.err(.duplicate_function, f.name_span, message, "duplicate definition", null);
            continue;
        }
        try table.map.put(gpa, f.name, .{ .function = index });

        if (std.mem.eql(u8, f.name, entry_name)) {
            table.entry = index;
            const only_allocator = f.params.len == 1 and table.fns[index].params[0] == .allocator;
            if (f.params.len != 0 and !only_allocator) {
                try diags.err(
                    .bad_signature,
                    f.name_span,
                    "`main` takes nothing, or one `Allocator`",
                    "remove the parameters",
                    "write `fn main(alloc: Allocator)` to allocate",
                );
            }
            if (table.fns[index].ret != .void) {
                try diags.err(
                    .bad_signature,
                    f.ret_ty.?.spanOf(),
                    "`main` cannot return a value",
                    "remove the return type",
                    null,
                );
            }
        }
    }

    if (table.entry == null) {
        try diags.err(
            .missing_main,
            null,
            "no `main` function found",
            null,
            "every Relastic program needs `fn main() { ... }`",
        );
    }

    return table;
}
