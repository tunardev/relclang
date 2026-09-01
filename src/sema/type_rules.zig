const std = @import("std");
const ast = @import("../syntax/ast.zig");
const types = @import("types.zig");

pub fn typeFromName(name: []const u8) ?types.Type {
    if (std.mem.eql(u8, name, "Int")) return .int;
    if (std.mem.eql(u8, name, "Bool")) return .bool;
    if (std.mem.eql(u8, name, "Allocator")) return .allocator;
    if (std.mem.eql(u8, name, "String")) return .string;
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
