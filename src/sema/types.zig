const std = @import("std");

pub const Type = union(enum) {
    void,
    bool,
    int,
    str,
    invalid,
    strukt: u32,
    enumeration: u32,
    array: Array,
    ref: Ref,
    param: u32,
    allocator,
    vec: Vec,

    pub const Array = struct {
        elem: *const Type,
        len: u64,
    };

    pub const Ref = struct {
        mutable: bool,
        target: *const Type,
    };

    pub const Vec = struct {
        elem: *const Type,
    };

    pub fn eql(a: Type, b: Type) bool {
        return switch (a) {
            .void => b == .void,
            .bool => b == .bool,
            .int => b == .int,
            .str => b == .str,
            .invalid => b == .invalid,
            .strukt => |i| b == .strukt and b.strukt == i,
            .enumeration => |i| b == .enumeration and b.enumeration == i,
            .array => |x| b == .array and x.len == b.array.len and eql(x.elem.*, b.array.elem.*),
            .ref => |r| b == .ref and r.mutable == b.ref.mutable and eql(r.target.*, b.ref.target.*),
            .param => |i| b == .param and b.param == i,
            .allocator => b == .allocator,
            .vec => |v| b == .vec and eql(v.elem.*, b.vec.elem.*),
        };
    }

    pub fn isInvalid(t: Type) bool {
        return switch (t) {
            .invalid => true,
            .array => |a| a.elem.isInvalid(),
            .ref => |r| r.target.isInvalid(),
            .vec => |v| v.elem.isInvalid(),
            else => false,
        };
    }
};

pub const Field = struct {
    name: []const u8,
    ty: Type,
    span_name: u32,
};

pub const StructDef = struct {
    name: []const u8,
    fields: []const Field,

    pub fn fieldIndex(d: StructDef, name: []const u8) ?u32 {
        for (d.fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) return @intCast(i);
        }
        return null;
    }
};

pub const VariantDef = struct {
    name: []const u8,
    payload: []const Type,
};

pub const EnumDef = struct {
    name: []const u8,
    variants: []const VariantDef,

    pub fn variantIndex(d: EnumDef, name: []const u8) ?u32 {
        for (d.variants, 0..) |v, i| {
            if (std.mem.eql(u8, v.name, name)) return @intCast(i);
        }
        return null;
    }
};

pub const Registry = struct {
    structs: []const StructDef,
    enums: []const EnumDef,
};

pub fn hasParam(t: Type) bool {
    return switch (t) {
        .param => true,
        .array => |a| hasParam(a.elem.*),
        .ref => |r| hasParam(r.target.*),
        .vec => |v| hasParam(v.elem.*),
        else => false,
    };
}

pub fn needsDrop(t: Type) bool {
    return switch (t) {
        .vec => true,
        else => false,
    };
}

pub fn substitute(arena: std.mem.Allocator, t: Type, args: []const Type) error{OutOfMemory}!Type {
    return switch (t) {
        .param => |i| if (i < args.len) args[i] else t,
        .array => |a| blk: {
            const elem = try arena.create(Type);
            elem.* = try substitute(arena, a.elem.*, args);
            break :blk .{ .array = .{ .elem = elem, .len = a.len } };
        },
        .ref => |r| blk: {
            const target = try arena.create(Type);
            target.* = try substitute(arena, r.target.*, args);
            break :blk .{ .ref = .{ .mutable = r.mutable, .target = target } };
        },
        .vec => |v| blk: {
            const elem = try arena.create(Type);
            elem.* = try substitute(arena, v.elem.*, args);
            break :blk .{ .vec = .{ .elem = elem } };
        },
        else => t,
    };
}

pub fn unify(declared: Type, actual: Type, out: []?Type) bool {
    return switch (declared) {
        .param => |i| blk: {
            if (i >= out.len) break :blk false;
            if (out[i]) |bound| break :blk Type.eql(bound, actual);
            out[i] = actual;
            break :blk true;
        },
        .array => |a| actual == .array and a.len == actual.array.len and
            unify(a.elem.*, actual.array.elem.*, out),
        .ref => |r| actual == .ref and r.mutable == actual.ref.mutable and
            unify(r.target.*, actual.ref.target.*, out),
        .vec => |v| actual == .vec and unify(v.elem.*, actual.vec.elem.*, out),
        else => Type.eql(declared, actual),
    };
}

pub fn isCopy(t: Type) bool {
    return switch (t) {
        .void, .bool, .int, .str, .invalid => true,
        .ref => true,
        .allocator => true,
        .vec => false,
        .param => false,
        .strukt, .enumeration => false,
        .array => |a| isCopy(a.elem.*),
    };
}

pub fn nameOf(arena: std.mem.Allocator, reg: Registry, t: Type) ![]const u8 {
    return switch (t) {
        .void => "Void",
        .bool => "Bool",
        .int => "Int",
        .str => "Str",
        .invalid => "<invalid>",
        .strukt => |i| if (i < reg.structs.len) reg.structs[i].name else "<struct>",
        .enumeration => |i| if (i < reg.enums.len) reg.enums[i].name else "<enum>",
        .array => |a| std.fmt.allocPrint(arena, "[{s}; {d}]", .{
            try nameOf(arena, reg, a.elem.*),
            a.len,
        }),
        .param => |i| std.fmt.allocPrint(arena, "T{d}", .{i}),
        .allocator => "Allocator",
        .vec => |v| std.fmt.allocPrint(arena, "Vec<{s}>", .{try nameOf(arena, reg, v.elem.*)}),
        .ref => |r| std.fmt.allocPrint(arena, "&{s}{s}", .{
            if (r.mutable) "mut " else "",
            try nameOf(arena, reg, r.target.*),
        }),
    };
}
