const std = @import("std");
const tir = @import("../../ir/tir.zig");
const types = @import("../../sema/types.zig");
const runtime = @import("../runtime.zig");

pub const prefix = "rc_";
pub const Error = error{ OutOfMemory, WriteFailed };



pub fn emitType(w: *std.Io.Writer, program: tir.Program, ty: types.Type) Error!void {
    switch (ty) {
        .void, .invalid, .param => try w.writeAll("void"),
        .allocator => try w.writeAll("rt.Allocator"),
        .string => try w.writeAll("rt.String"),
        .vec => |v| {
            try w.writeAll("rt.Vec(");
            try emitType(w, program, v.elem.*);
            try w.writeAll(")");
        },
        .bool => try w.writeAll("bool"),
        .int => try w.writeAll("i64"),
        .str => try w.writeAll("[]const u8"),
        .ref => |r| {
            try w.writeAll(if (r.mutable) "*" else "*const ");
            try emitType(w, program, r.target.*);
        },
        .strukt => |i| try w.print("S{d}_{s}", .{ i, program.structs[i].name }),
        .enumeration => |i| try w.print("E{d}_{s}", .{ i, program.enums[i].name }),
        .array => |a| {
            try w.print("[{d}]", .{a.len});
            try emitType(w, program, a.elem.*);
        },
    }
}
