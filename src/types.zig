const std = @import("std");

pub const Type = union(enum) {
    void,
    int,
    str,
    invalid,
    strukt: u32,
    array: Array,

    pub const Array = struct {
        elem: *const Type,
        len: u64,
    };

    pub fn eql(a: Type, b: Type) bool {
        return switch (a) {
            .void => b == .void,
            .int => b == .int,
            .str => b == .str,
            .invalid => b == .invalid,
            .strukt => |i| b == .strukt and b.strukt == i,
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

pub fn nameOf(arena: std.mem.Allocator, structs: []const StructDef, t: Type) ![]const u8 {
    return switch (t) {
        .void => "Void",
        .int => "Int",
        .str => "Str",
        .invalid => "<invalid>",
        .strukt => |i| if (i < structs.len) structs[i].name else "<struct>",
        .array => |a| std.fmt.allocPrint(arena, "[{s}; {d}]", .{
            try nameOf(arena, structs, a.elem.*),
            a.len,
        }),
    };
}

const testing = std.testing;

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

    const structs = [_]StructDef{.{ .name = "Point", .fields = &.{} }};
    const int_ty: Type = .int;
    const inner: Type = .{ .array = .{ .elem = &int_ty, .len = 3 } };

    try testing.expectEqualStrings("Int", try nameOf(arena, &structs, .int));
    try testing.expectEqualStrings("Point", try nameOf(arena, &structs, .{ .strukt = 0 }));
    try testing.expectEqualStrings("[Int; 3]", try nameOf(arena, &structs, inner));
    try testing.expectEqualStrings("[[Int; 3]; 2]", try nameOf(arena, &structs, .{ .array = .{ .elem = &inner, .len = 2 } }));
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
