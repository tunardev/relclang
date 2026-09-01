const std = @import("std");
const ast = @import("../syntax/ast.zig");
const types = @import("types.zig");
const impl = @import("type_rules.zig");

const binaryResult = impl.binaryResult;
const typeFromName = impl.typeFromName;
const unaryResult = impl.unaryResult;

const testing = std.testing;

test "Bool is a known type name" {
    try testing.expect(types.Type.eql(.bool, typeFromName("Bool").?));
}

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
