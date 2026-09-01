const std = @import("std");
const impl = @import("types.zig");

const EnumDef = impl.EnumDef;
const Registry = impl.Registry;
const StructDef = impl.StructDef;
const Type = impl.Type;
const hasParam = impl.hasParam;
const isCopy = impl.isCopy;
const nameOf = impl.nameOf;
const substitute = impl.substitute;
const unify = impl.unify;

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

test "references are copy and compare by mutability and target" {
    const int_ty: Type = .int;
    const shared: Type = .{ .ref = .{ .mutable = false, .target = &int_ty } };
    const exclusive: Type = .{ .ref = .{ .mutable = true, .target = &int_ty } };

    try testing.expect(isCopy(shared));
    try testing.expect(Type.eql(shared, .{ .ref = .{ .mutable = false, .target = &int_ty } }));
    try testing.expect(!Type.eql(shared, exclusive));
}

test "reference names render with mut" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reg: Registry = .{ .structs = &.{}, .enums = &.{} };
    const int_ty: Type = .int;

    try testing.expectEqualStrings("&Int", try nameOf(arena, reg, .{ .ref = .{ .mutable = false, .target = &int_ty } }));
    try testing.expectEqualStrings("&mut Int", try nameOf(arena, reg, .{ .ref = .{ .mutable = true, .target = &int_ty } }));
}

test "substitution replaces parameters" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p0: Type = .{ .param = 0 };
    const args = [_]Type{.int};

    try testing.expect(Type.eql(.int, try substitute(arena, p0, &args)));

    const arr: Type = .{ .array = .{ .elem = &p0, .len = 3 } };
    const out = try substitute(arena, arr, &args);
    try testing.expect(Type.eql(.int, out.array.elem.*));
    try testing.expectEqual(@as(u64, 3), out.array.len);
}

test "unification binds and then checks parameters" {
    var out = [_]?Type{null};
    const p0: Type = .{ .param = 0 };

    try testing.expect(unify(p0, .int, &out));
    try testing.expect(Type.eql(.int, out[0].?));
    try testing.expect(unify(p0, .int, &out));
    try testing.expect(!unify(p0, .str, &out));
}

test "unification descends through references" {
    var out = [_]?Type{null};
    const p0: Type = .{ .param = 0 };
    const int_ty: Type = .int;
    const declared: Type = .{ .ref = .{ .mutable = false, .target = &p0 } };
    const actual: Type = .{ .ref = .{ .mutable = false, .target = &int_ty } };

    try testing.expect(unify(declared, actual, &out));
    try testing.expect(Type.eql(.int, out[0].?));
}

test "hasParam finds nested parameters" {
    const p0: Type = .{ .param = 0 };
    try testing.expect(hasParam(p0));
    try testing.expect(hasParam(.{ .ref = .{ .mutable = false, .target = &p0 } }));
    try testing.expect(!hasParam(.int));
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
