const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");

pub fn typeFromName(name: []const u8) ?types.Type {
    if (std.mem.eql(u8, name, "Int")) return .int;
    if (std.mem.eql(u8, name, "Str")) return .str;
    if (std.mem.eql(u8, name, "Void")) return .void;
    return null;
}

pub fn binaryResult(op: ast.BinOp, lhs: types.Type, rhs: types.Type) ?types.Type {
    if (lhs == .invalid or rhs == .invalid) return .invalid;
    return switch (op) {
        .add, .sub, .mul, .div, .rem => if (lhs == .int and rhs == .int) .int else null,
    };
}

pub fn unaryResult(op: ast.UnOp, operand: types.Type) ?types.Type {
    if (operand == .invalid) return .invalid;
    return switch (op) {
        .neg => if (operand == .int) .int else null,
    };
}

const testing = std.testing;

test "type names map to types" {
    try testing.expectEqual(types.Type.int, typeFromName("Int").?);
    try testing.expectEqual(types.Type.str, typeFromName("Str").?);
    try testing.expectEqual(types.Type.void, typeFromName("Void").?);
    try testing.expect(typeFromName("Nope") == null);
}

test "arithmetic is int only" {
    try testing.expectEqual(types.Type.int, binaryResult(.add, .int, .int).?);
    try testing.expectEqual(types.Type.int, binaryResult(.rem, .int, .int).?);
    try testing.expect(binaryResult(.add, .str, .str) == null);
    try testing.expect(binaryResult(.add, .int, .str) == null);
    try testing.expect(binaryResult(.mul, .void, .int) == null);
}

test "negation is int only" {
    try testing.expectEqual(types.Type.int, unaryResult(.neg, .int).?);
    try testing.expect(unaryResult(.neg, .str) == null);
}

test "an invalid operand propagates instead of cascading" {
    try testing.expectEqual(types.Type.invalid, binaryResult(.add, .invalid, .int).?);
    try testing.expectEqual(types.Type.invalid, unaryResult(.neg, .invalid).?);
}
