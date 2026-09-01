const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");

pub fn typeFromName(name: []const u8) ?types.Type {
    if (std.mem.eql(u8, name, "Int")) return .int;
    if (std.mem.eql(u8, name, "Str")) return .str;
    if (std.mem.eql(u8, name, "Void")) return .void;
    return null;
}

pub fn isComparable(t: types.Type) bool {
    return switch (t) {
        .int, .bool, .str => true,
        else => false,
    };
}

pub fn binaryResult(op: ast.BinOp, lhs: types.Type, rhs: types.Type) ?types.Type {
    if (lhs.isInvalid() or rhs.isInvalid()) return .invalid;
    return switch (op) {
        .add, .sub, .mul, .div, .rem => if (lhs == .int and rhs == .int) .int else null,
        .lt, .gt, .le, .ge => if (lhs == .int and rhs == .int) .bool else null,
        .eq, .ne => if (types.Type.eql(lhs, rhs) and isComparable(lhs)) .bool else null,
        .logical_and, .logical_or => if (lhs == .bool and rhs == .bool) .bool else null,
    };
}

pub fn unaryResult(op: ast.UnOp, operand: types.Type) ?types.Type {
    if (operand.isInvalid()) return .invalid;
    return switch (op) {
        .neg => if (operand == .int) .int else null,
        .not => if (operand == .bool) .bool else null,
    };
}

const testing = std.testing;

test "type names map to types" {
    try testing.expect(types.Type.eql(.int, typeFromName("Int").?));
    try testing.expect(types.Type.eql(.str, typeFromName("Str").?));
    try testing.expect(types.Type.eql(.void, typeFromName("Void").?));
    try testing.expect(typeFromName("Nope") == null);
}

test "arithmetic is int only" {
    try testing.expect(types.Type.eql(.int, binaryResult(.add, .int, .int).?));
    try testing.expect(types.Type.eql(.int, binaryResult(.rem, .int, .int).?));
    try testing.expect(binaryResult(.add, .str, .str) == null);
    try testing.expect(binaryResult(.add, .int, .str) == null);
    try testing.expect(binaryResult(.mul, .void, .int) == null);
}

test "comparisons produce Bool" {
    try testing.expect(types.Type.eql(.bool, binaryResult(.lt, .int, .int).?));
    try testing.expect(types.Type.eql(.bool, binaryResult(.eq, .str, .str).?));
    try testing.expect(types.Type.eql(.bool, binaryResult(.eq, .bool, .bool).?));
    try testing.expect(binaryResult(.lt, .str, .str) == null);
    try testing.expect(binaryResult(.eq, .int, .str) == null);
    try testing.expect(binaryResult(.eq, .{ .strukt = 0 }, .{ .strukt = 0 }) == null);
}

test "logical operators are bool only" {
    try testing.expect(types.Type.eql(.bool, binaryResult(.logical_and, .bool, .bool).?));
    try testing.expect(binaryResult(.logical_or, .int, .int) == null);
    try testing.expect(types.Type.eql(.bool, unaryResult(.not, .bool).?));
    try testing.expect(unaryResult(.not, .int) == null);
}

test "negation is int only" {
    try testing.expect(types.Type.eql(.int, unaryResult(.neg, .int).?));
    try testing.expect(unaryResult(.neg, .str) == null);
}

test "an invalid operand propagates instead of cascading" {
    try testing.expect(types.Type.eql(.invalid, binaryResult(.add, .invalid, .int).?));
    try testing.expect(types.Type.eql(.invalid, unaryResult(.neg, .invalid).?));
}
