const std = @import("std");
const source = @import("source.zig");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const types = @import("types.zig");
const typecheck = @import("typecheck.zig");

pub const Builtin = enum {
    println,

    pub fn arity(b: Builtin) usize {
        return switch (b) {
            .println => 1,
        };
    }

    pub fn resultType(b: Builtin) types.Type {
        return switch (b) {
            .println => .void,
        };
    }

    pub fn accepts(b: Builtin, index: usize, ty: types.Type) bool {
        return switch (b) {
            .println => index == 0 and (ty == .str or ty == .int or ty == .bool),
        };
    }

    pub fn describeParam(b: Builtin, index: usize) []const u8 {
        return switch (b) {
            .println => if (index == 0) "`Str`, `Int` or `Bool`" else "nothing",
        };
    }
};

pub const VariantRef = struct {
    enumeration: u32,
    variant: u32,
    from_template: bool = false,
};

pub const Symbol = union(enum) {
    builtin: Builtin,
    function: usize,
    variant: VariantRef,
};

pub const FnInfo = struct {
    name: []const u8,
    params: []const types.Type,
    ret: types.Type,
    type_param_count: u32,

    pub fn isGeneric(i: FnInfo) bool {
        return i.type_param_count > 0;
    }
};

pub const Template = struct {
    name: []const u8,
    type_param_count: u32,
    struct_def: ?types.StructDef,
    enum_def: ?types.EnumDef,
};

pub const TypeInstance = struct {
    template: u32,
    args: []const types.Type,
    index: u32,
};

pub const SymbolTable = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Symbol),
    entry: ?usize,
    fns: []const FnInfo,
    structs: std.ArrayList(types.StructDef),
    struct_map: std.StringHashMapUnmanaged(u32),
    enums: std.ArrayList(types.EnumDef),
    enum_map: std.StringHashMapUnmanaged(u32),
    templates: std.ArrayList(Template),
    template_map: std.StringHashMapUnmanaged(u32),
    instances: std.ArrayList(TypeInstance),

    pub fn lookup(t: *const SymbolTable, name: []const u8) ?Symbol {
        return t.map.get(name);
    }

    pub fn signature(t: *const SymbolTable, index: usize) FnInfo {
        return t.fns[index];
    }

    pub fn structIndex(t: *const SymbolTable, name: []const u8) ?u32 {
        return t.struct_map.get(name);
    }

    pub fn templateIndex(t: *const SymbolTable, name: []const u8) ?u32 {
        return t.template_map.get(name);
    }

    fn findInstance(t: *const SymbolTable, template: u32, args: []const types.Type) ?u32 {
        outer: for (t.instances.items) |inst| {
            if (inst.template != template) continue;
            if (inst.args.len != args.len) continue;
            for (inst.args, args) |a, b| {
                if (!types.Type.eql(a, b)) continue :outer;
            }
            return inst.index;
        }
        return null;
    }

    pub fn instantiate(t: *SymbolTable, template: u32, args: []const types.Type) !types.Type {
        const tpl = t.templates.items[template];

        if (t.findInstance(template, args)) |index| {
            return if (tpl.struct_def != null) .{ .strukt = index } else .{ .enumeration = index };
        }

        const owned = try t.arena.dupe(types.Type, args);
        const suffix = try instanceSuffix(t, tpl.name, args);

        if (tpl.struct_def) |def| {
            const index: u32 = @intCast(t.structs.items.len);
            try t.instances.append(t.gpa, .{ .template = template, .args = owned, .index = index });

            const fields = try t.arena.alloc(types.Field, def.fields.len);
            try t.structs.append(t.arena, .{ .name = suffix, .fields = fields });

            for (def.fields, 0..) |field, i| {
                fields[i] = .{
                    .name = field.name,
                    .ty = try types.substitute(t.arena, field.ty, args),
                    .span_name = field.span_name,
                };
            }
            return .{ .strukt = index };
        }

        const def = tpl.enum_def.?;
        const index: u32 = @intCast(t.enums.items.len);
        try t.instances.append(t.gpa, .{ .template = template, .args = owned, .index = index });

        const variants = try t.arena.alloc(types.VariantDef, def.variants.len);
        try t.enums.append(t.arena, .{ .name = suffix, .variants = variants });

        for (def.variants, 0..) |variant, i| {
            const payload = try t.arena.alloc(types.Type, variant.payload.len);
            for (variant.payload, 0..) |ty, j| {
                payload[j] = try types.substitute(t.arena, ty, args);
            }
            variants[i] = .{ .name = variant.name, .payload = payload };
        }

        return .{ .enumeration = index };
    }

    pub fn enumIndex(t: *const SymbolTable, name: []const u8) ?u32 {
        return t.enum_map.get(name);
    }

    pub fn registry(t: *const SymbolTable) types.Registry {
        return .{ .structs = t.structs.items, .enums = t.enums.items };
    }

    pub fn typeName(t: *const SymbolTable, arena: std.mem.Allocator, ty: types.Type) ![]const u8 {
        return types.nameOf(arena, t.registry(), ty);
    }

    pub fn deinit(t: *SymbolTable) void {
        t.map.deinit(t.gpa);
        t.struct_map.deinit(t.gpa);
        t.enum_map.deinit(t.gpa);
        t.template_map.deinit(t.gpa);
        t.instances.deinit(t.gpa);
    }
};

const entry_name = "main";

fn instanceSuffix(
    t: *const SymbolTable,
    name: []const u8,
    args: []const types.Type,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(t.arena, name);
    for (args) |arg| {
        try out.append(t.arena, '_');
        const text = try types.nameOf(t.arena, t.registry(), arg);
        for (text) |ch| {
            try out.append(t.arena, switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9' => ch,
                else => '_',
            });
        }
    }
    return out.toOwnedSlice(t.arena);
}

pub fn resolveType(
    arena: std.mem.Allocator,
    table: *SymbolTable,
    expr: ast.TypeExpr,
    diags: *diagnostics.Diagnostics,
) !types.Type {
    return resolveTypeIn(arena, table, expr, &.{}, diags);
}

fn resolveTypeIn(
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

                if (types.hasParam(.{ .array = .{ .elem = &args[0], .len = 0 } }) and false) return .invalid;
                return table.instantiate(tpl_index, args) catch error.OutOfMemory;
            }

            if (table.structIndex(n.name)) |index| return .{ .strukt = index };
            if (table.enumIndex(n.name)) |index| return .{ .enumeration = index };

            try diags.err(
                .unknown_struct,
                n.span,
                try diags.fmt("unknown type `{s}`", .{n.name}),
                "not a known type",
                "the built in types are `Int`, `Bool`, `Str` and `Void`",
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

fn structDepth(
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
    };
    errdefer table.deinit();

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
                try payload.append(arena, try resolveTypeIn(arena, &table, ty_expr, decl.type_params, diags));
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
            try fields.append(arena, .{
                .name = field.name,
                .ty = try resolveTypeIn(arena, &table, field.ty, decl.type_params, diags),
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

    var infos: std.ArrayList(FnInfo) = .empty;

    for (program.fns) |f| {
        var params: std.ArrayList(types.Type) = .empty;
        for (f.params) |param| {
            try params.append(arena, try resolveTypeIn(arena, &table, param.ty, f.type_params, diags));
        }

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
            if (f.params.len != 0) {
                try diags.err(
                    .bad_signature,
                    f.name_span,
                    "`main` cannot take parameters",
                    "remove the parameters",
                    null,
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

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    diags: diagnostics.Diagnostics,
    symbols: SymbolTable,

    fn deinit(f: *Fixture) void {
        f.symbols.deinit();
        f.diags.deinit();
        f.arena.deinit();
    }
};

fn resolveText(gpa: std.mem.Allocator, text: []const u8) !Fixture {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    var d: diagnostics.Diagnostics = .init(gpa);
    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    const toks = try lexer.tokenize(arena_state.allocator(), file, &d);
    const program = try parser.parse(arena_state.allocator(), toks, &d);
    const symbols = try run(arena_state.allocator(), gpa, program, &d);
    return .{ .arena = arena_state, .diags = d, .symbols = symbols };
}

fn hasCode(d: diagnostics.Diagnostics, code: diagnostics.Code) bool {
    for (d.list.items) |item| {
        if (item.code == code) return true;
    }
    return false;
}

test "resolves main and the println builtin" {
    var f = try resolveText(testing.allocator, "fn main() {\n    println(\"hi\")\n}\n");
    defer f.deinit();

    try testing.expect(!f.diags.hasErrors());
    try testing.expectEqual(@as(?usize, 0), f.symbols.entry);
    try testing.expectEqual(Builtin.println, f.symbols.lookup("println").?.builtin);
    try testing.expectEqual(@as(usize, 0), f.symbols.lookup("main").?.function);
}

test "missing main reports E0005" {
    var f = try resolveText(testing.allocator, "fn other() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .missing_main));
}

test "duplicate function reports E0006" {
    var f = try resolveText(testing.allocator, "fn main() {\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .duplicate_function));
}

test "shadowing a builtin reports E0006" {
    var f = try resolveText(testing.allocator, "fn println() {\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .duplicate_function));
}

test "registers every declared function" {
    var f = try resolveText(testing.allocator, "fn helper() {\n}\nfn main() {\n    helper()\n}\n");
    defer f.deinit();
    try testing.expect(!f.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), f.symbols.lookup("helper").?.function);
    try testing.expectEqual(@as(usize, 1), f.symbols.lookup("main").?.function);
}

test "a function may be called before it is defined" {
    var f = try resolveText(testing.allocator, "fn main() {\n    helper()\n}\nfn helper() {\n}\n");
    defer f.deinit();
    try testing.expect(!f.diags.hasErrors());
}

test "entry index points at main even when it is not first" {
    var f = try resolveText(testing.allocator, "fn helper() {\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expectEqual(@as(?usize, 1), f.symbols.entry);
}

test "a recursive struct reports E0021" {
    var f = try resolveText(testing.allocator, "struct Node {\n    next: Node\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .recursive_struct));
}

test "a mutually recursive struct pair reports E0021" {
    var f = try resolveText(testing.allocator, "struct A {\n    b: B\n}\nstruct B {\n    a: A\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .recursive_struct));
}

test "a struct referring to another struct is fine" {
    var f = try resolveText(testing.allocator, "struct Inner {\n    v: Int\n}\nstruct Outer {\n    i: Inner\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(!f.diags.hasErrors());
}

test "a duplicate struct name is reported" {
    var f = try resolveText(testing.allocator, "struct P {\n    x: Int\n}\nstruct P {\n    y: Int\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .duplicate_function));
}

test "an unknown type in a signature reports E0018" {
    var f = try resolveText(testing.allocator, "fn f(a: Nope) {\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .unknown_struct));
}
