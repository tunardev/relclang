const std = @import("std");
const tir = @import("../../ir/tir.zig");
const types = @import("../../sema/types.zig");

const zig_types = @import("types.zig");
const Error = zig_types.Error;
const regOf = zig_types.regOf;

const expr_mod = @import("expr.zig");
const emitExpr = expr_mod.emitExpr;
const emitOwned = expr_mod.emitOwned;
const emitLocalName = expr_mod.emitLocalName;
const emitFlagName = expr_mod.emitFlagName;
const needsFlag = expr_mod.needsFlag;

pub fn emitOwnedGuard(
    w: *std.Io.Writer,
    program: tir.Program,
    f: tir.Function,
    slot: u32,
    level: usize,
) Error!void {
    if (needsFlag(program, f, slot)) {
        try indent(w, level);
        try w.writeAll("var ");
        try emitFlagName(w, f, slot);
        try w.writeAll(" = true;\n");
        try indent(w, level);
        try w.writeAll("defer if (");
        try emitFlagName(w, f, slot);
        try w.writeAll(") rt.drop(&");
        try emitLocalName(w, f, slot);
        try w.writeAll(");\n");
        return;
    }
    try indent(w, level);
    try w.writeAll("defer rt.drop(&");
    try emitLocalName(w, f, slot);
    try w.writeAll(");\n");
}

fn emitAssign(
    w: *std.Io.Writer,
    program: tir.Program,
    f: tir.Function,
    lbl: *u32,
    a: tir.Assign,
    level: usize,
) Error!void {
    try indent(w, level);

    if (!types.needsDrop(a.target.typeOf(), regOf(program))) {
        try emitExpr(w, program, f, lbl, a.target);
        try w.writeAll(" = ");
        try emitOwned(w, program, f, lbl, a.value);
        try w.writeAll(";\n");
        return;
    }

    const flagged = a.target == .local_ref and needsFlag(program, f, a.target.local_ref.slot);

    try w.writeAll("{ const __new = ");
    try emitOwned(w, program, f, lbl, a.value);
    try w.writeAll("; ");
    if (flagged) {
        try w.writeAll("if (");
        try emitFlagName(w, f, a.target.local_ref.slot);
        try w.writeAll(") ");
    }
    try w.writeAll("rt.drop(&");
    try emitExpr(w, program, f, lbl, a.target);
    try w.writeAll("); ");
    try emitExpr(w, program, f, lbl, a.target);
    try w.writeAll(" = __new; ");
    if (flagged) {
        try emitFlagName(w, f, a.target.local_ref.slot);
        try w.writeAll(" = true; ");
    }
    try w.writeAll("}\n");
}

fn emitStmt(
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
        .assign => |a| try emitAssign(w, program, f, lbl, a, level),
        .ret => |r| {
            try indent(w, level);
            if (r.value) |v| {
                try w.writeAll("return ");
                try emitOwned(w, program, f, lbl, v);
                try w.writeAll(";\n");
            } else {
                try w.writeAll("return;\n");
            }
        },
        .let => |l| {
            const owned = types.needsDrop(f.locals[l.slot].ty, regOf(program));
            try indent(w, level);
            try w.writeAll(if (owned or f.locals[l.slot].assigned) "var " else "const ");
            try emitLocalName(w, f, l.slot);
            try w.writeAll(" = ");
            try emitOwned(w, program, f, lbl, l.init);
            try w.writeAll(";\n");
            if (owned) try emitOwnedGuard(w, program, f, l.slot, level);
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
    if (block.result == null and block.diverges()) {
        try w.writeAll("{\n");
        try emitBlockBody(w, program, f, lbl, block, 3);
        try w.writeAll("    }");
        return;
    }

    const id = lbl.*;
    lbl.* += 1;

    try w.print("b{d}: {{\n", .{id});
    try emitBlockBody(w, program, f, lbl, block, 3);
    try indent(w, 3);
    try w.print("break :b{d} ", .{id});
    if (block.result) |r| {
        try emitOwned(w, program, f, lbl, r.*);
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
