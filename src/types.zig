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

    pub const Array = struct {
        elem: *const Type,
        len: u64,
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
        };
    }

    pub fn isInvalid(t: Type) bool {
        return switch (t) {
            .invalid => true,
            .array => |a| a.elem.isInvalid(),
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

pub fn isCopy(t: Type) bool {
    return switch (t) {
        .void, .bool, .int, .str, .invalid => true,
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
    };
}

const testing = std.testing;

test "enum equality" {
    try testing.expect(Type.eql(.{ .enumeration = 1 }, .{ .enumeration = 1 }));
    try testing.expect(!Type.eql(.{ .enumeration = 1 }, .{ .enumeration = 2 }));
    try testing.expect(!Type.eql(.{ .enumeration = 1 }, .{ .strukt = 1 }));
}

test "variant lookup by name" {
    const def: EnumDef = .{ .name = "S", .variants = &.{
        .{ .name = "A", .payload = &.{} },
        .{ .name = "B", .payload = &.{.int} },
    } };
    try testing.expectEqual(@as(u32, 1), def.variantIndex("B").?);
    try testing.expect(def.variantIndex("C") == null);
}

test "primitive equality" {
    try testing.expect(Type.eql(.int, .int));
    try testing.expect(!Type.eql(.int, .str));
    try testing.expect(Type.eql(.{ .strukt = 2 }, .{ .strukt = 2 }));
    try testing.expect(!Type.eql(.{ .strukt = 2 }, .{ .strukt = 3 }));
}

test "array equality compares length and element" {
    const int_ty: Type = .int;
    const str_ty: Type = .str;
    const a: Type = .{ .array = .{ .elem = &int_ty, .len = 3 } };
    const b: Type = .{ .array = .{ .elem = &int_ty, .len = 3 } };
    const c: Type = .{ .array = .{ .elem = &int_ty, .len = 4 } };
    const d: Type = .{ .array = .{ .elem = &str_ty, .len = 3 } };

    try testing.expect(Type.eql(a, b));
    try testing.expect(!Type.eql(a, c));
    try testing.expect(!Type.eql(a, d));
}

test "names render primitives, structs and arrays" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reg: Registry = .{
        .structs = &.{.{ .name = "Point", .fields = &.{} }},
        .enums = &.{.{ .name = "Shape", .variants = &.{} }},
    };
    const int_ty: Type = .int;
    const inner: Type = .{ .array = .{ .elem = &int_ty, .len = 3 } };

    try testing.expectEqualStrings("Int", try nameOf(arena, reg, .int));
    try testing.expectEqualStrings("Point", try nameOf(arena, reg, .{ .strukt = 0 }));
    try testing.expectEqualStrings("Shape", try nameOf(arena, reg, .{ .enumeration = 0 }));
    try testing.expectEqualStrings("[Int; 3]", try nameOf(arena, reg, inner));
    try testing.expectEqualStrings("[[Int; 3]; 2]", try nameOf(arena, reg, .{ .array = .{ .elem = &inner, .len = 2 } }));
}

test "primitives are copy and aggregates are not" {
    try testing.expect(isCopy(.int));
    try testing.expect(isCopy(.bool));
    try testing.expect(isCopy(.str));
    try testing.expect(!isCopy(.{ .strukt = 0 }));
    try testing.expect(!isCopy(.{ .enumeration = 0 }));
}

test "an array is copy exactly when its element is" {
    const int_ty: Type = .int;
    const p_ty: Type = .{ .strukt = 0 };
    try testing.expect(isCopy(.{ .array = .{ .elem = &int_ty, .len = 3 } }));
    try testing.expect(!isCopy(.{ .array = .{ .elem = &p_ty, .len = 3 } }));
}

test "an array of invalid is invalid" {
    const bad: Type = .invalid;
    const arr: Type = .{ .array = .{ .elem = &bad, .len = 2 } };
    try testing.expect(arr.isInvalid());
    try testing.expect(!Type.isInvalid(.int));
}

test "field lookup by name" {
    const def: StructDef = .{ .name = "P", .fields = &.{
        .{ .name = "x", .ty = .int, .span_name = 0 },
        .{ .name = "y", .ty = .int, .span_name = 0 },
    } };
    try testing.expectEqual(@as(u32, 1), def.fieldIndex("y").?);
    try testing.expect(def.fieldIndex("z") == null);
}
