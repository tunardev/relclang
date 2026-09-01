const std = @import("std");
const types = @import("types.zig");
const ast = @import("../syntax/ast.zig");

pub const Builtin = enum {
    println,
    read_line,

    pub fn arity(b: Builtin) usize {
        return switch (b) {
            .println => 1,
            .read_line => 1,
        };
    }

    pub fn resultType(b: Builtin) types.Type {
        return switch (b) {
            .println => .void,
            .read_line => .string,
        };
    }

    pub fn accepts(b: Builtin, index: usize, ty: types.Type) bool {
        return switch (b) {
            .println => index == 0 and (ty == .str or ty == .int or ty == .bool or
                ty == .string or (ty == .ref and ty.ref.target.* == .string)),
            .read_line => index == 0 and ty == .allocator,
        };
    }

    pub fn describeParam(b: Builtin, index: usize) []const u8 {
        return switch (b) {
            .println => if (index == 0) "`Str`, `Int`, `Bool` or `String`" else "nothing",
            .read_line => if (index == 0) "`Allocator`" else "nothing",
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

pub const TraitInfo = struct {
    name: []const u8,
    methods: []const []const u8,

    pub fn hasMethod(t: TraitInfo, name: []const u8) bool {
        for (t.methods) |m| {
            if (std.mem.eql(u8, m, name)) return true;
        }
        return false;
    }
};

pub const ImplInfo = struct {
    trait_index: u32,
    target: types.Type,
    methods: []const usize,
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
    traits: []const TraitInfo,
    trait_map: std.StringHashMapUnmanaged(u32),
    impls: []const ImplInfo,
    all_fns: []const ast.Fn,
    bounds: []const []const u32,

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

    pub fn traitIndex(t: *const SymbolTable, name: []const u8) ?u32 {
        return t.trait_map.get(name);
    }

    pub fn findImpl(t: *const SymbolTable, target: types.Type, method: []const u8) ?struct {
        impl: ImplInfo,
        fn_index: usize,
    } {
        for (t.impls) |impl| {
            if (!types.Type.eql(impl.target, target)) continue;
            const trait = t.traits[impl.trait_index];
            for (trait.methods, 0..) |name, i| {
                if (!std.mem.eql(u8, name, method)) continue;
                if (i >= impl.methods.len) continue;
                return .{ .impl = impl, .fn_index = impl.methods[i] };
            }
        }
        return null;
    }

    pub fn implements(t: *const SymbolTable, target: types.Type, trait_index: u32) bool {
        for (t.impls) |impl| {
            if (impl.trait_index == trait_index and types.Type.eql(impl.target, target)) return true;
        }
        return false;
    }

    pub fn deinit(t: *SymbolTable) void {
        t.map.deinit(t.gpa);
        t.trait_map.deinit(t.gpa);
        t.struct_map.deinit(t.gpa);
        t.enum_map.deinit(t.gpa);
        t.template_map.deinit(t.gpa);
        t.instances.deinit(t.gpa);
    }
};

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
