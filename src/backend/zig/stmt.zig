const std = @import("std");
const tir = @import("../../ir/tir.zig");
const types = @import("../../sema/types.zig");
const runtime = @import("../runtime.zig");

pub const prefix = "rc_";
pub const Error = error{ OutOfMemory, WriteFailed };

const emitExpr = @import("expr.zig").emitExpr;
const emitLocalName = @import("expr.zig").emitLocalName;

pub fn emitStmt(
    w: *std.Io.Writer,
    program: tir.Program,
    f: tir.Function,
    lbl: *u32,
    stmt: tir.Stmt,
    level: usize,
) Error!void {
    switch (stmt) {
        .expr => |e| {
            try indent(w, level);
            try emitExpr(w, program, f, lbl, e);
            try w.writeAll(if (isBlockForm(e)) "\n" else ";\n");
        },
        .assign => |a| {
            try indent(w, level);
            try emitExpr(w, program, f, lbl, a.target);
            try w.writeAll(" = ");
            try emitExpr(w, program, f, lbl, a.value);
            try w.writeAll(";\n");
        },
        .ret => |r| {
            try indent(w, level);
            if (r.value) |v| {
                try w.writeAll("return ");
                try emitExpr(w, program, f, lbl, v);
                try w.writeAll(";\n");
            } else {
                try w.writeAll("return;\n");
            }
        },
        .let => |l| {
            try indent(w, level);
            try w.writeAll(if (f.locals[l.slot].assigned) "var " else "const ");
            try emitLocalName(w, f, l.slot);
            try w.writeAll(" = ");
            try emitExpr(w, program, f, lbl, l.init);
            try w.writeAll(";\n");
            if (!f.locals[l.slot].used) {
                try indent(w, level);
                try w.writeAll("_ = ");
                try emitLocalName(w, f, l.slot);
                try w.writeAll(";\n");
            }
        },
    }
}

pub fn emitBlockBody(
    w: *std.Io.Writer,
    program: tir.Program,
    f: tir.Function,
    lbl: *u32,
    block: tir.Block,
    level: usize,
) Error!void {
    for (block.stmts) |stmt| try emitStmt(w, program, f, lbl, stmt, level);
}

pub fn emitValueBlock(
    w: *std.Io.Writer,
    program: tir.Program,
    f: tir.Function,
    lbl: *u32,
    block: tir.Block,
) Error!void {
    const id = lbl.*;
    lbl.* += 1;

    try w.print("b{d}: {{\n", .{id});
    try emitBlockBody(w, program, f, lbl, block, 3);
    try indent(w, 3);
    try w.print("break :b{d} ", .{id});
    if (block.result) |r| {
        try emitExpr(w, program, f, lbl, r.*);
    } else {
        try w.writeAll("{}");
    }
    try w.writeAll(";\n    }");
}

pub fn emitVoidBlock(
    w: *std.Io.Writer,
    program: tir.Program,
    f: tir.Function,
    lbl: *u32,
    block: tir.Block,
) Error!void {
    try w.writeAll("{\n");
    try emitBlockBody(w, program, f, lbl, block, 3);
    if (block.result) |r| {
        try indent(w, 3);
        try emitExpr(w, program, f, lbl, r.*);
        try w.writeAll(";\n");
    }
    try indent(w, 1);
    try w.writeAll("}");
}

pub fn indent(w: *std.Io.Writer, level: usize) Error!void {
    try w.splatByteAll(' ', level * 4);
}

pub fn isBlockForm(e: tir.Expr) bool {
    return switch (e) {
        .match => |m| m.ty == .void or m.ty == .invalid,
        .if_expr => |i| i.ty == .void or i.ty == .invalid,
        .while_expr => true,
        else => false,
    };
}
