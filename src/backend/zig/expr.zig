const std = @import("std");
const tir = @import("../../ir/tir.zig");
const types = @import("../../sema/types.zig");

const zig_types = @import("types.zig");
const prefix = zig_types.prefix;
const Error = zig_types.Error;
const emitType = zig_types.emitType;
const regOf = zig_types.regOf;

const stmt_mod = @import("stmt.zig");
const emitValueBlock = stmt_mod.emitValueBlock;
const emitVoidBlock = stmt_mod.emitVoidBlock;
const emitBlockBody = stmt_mod.emitBlockBody;
const emitOwnedGuard = stmt_mod.emitOwnedGuard;
const indent = stmt_mod.indent;

pub fn needsFlag(program: tir.Program, f: tir.Function, slot: u32) bool {
    const local = f.locals[slot];
    return local.moved and types.needsDrop(local.ty, regOf(program));
}

fn placeRoot(e: tir.Expr) ?u32 {
    return switch (e) {
        .local_ref => |l| l.slot,
        .field => |x| placeRoot(x.base.*),
        else => null,
    };
}

pub fn moveRoot(program: tir.Program, f: tir.Function, e: tir.Expr) ?u32 {
    if (!types.needsDrop(e.typeOf(), regOf(program))) return null;
    const slot = placeRoot(e) orelse return null;
    return if (needsFlag(program, f, slot)) slot else null;
}

pub fn emitFlagName(w: *std.Io.Writer, f: tir.Function, slot: u32) Error!void {
    try w.print("v{d}_{s}_live", .{ slot, f.locals[slot].name });
}

fn emitMoveClear(w: *std.Io.Writer, program: tir.Program, f: tir.Function, lbl: *u32, e: tir.Expr) Error!void {
    switch (e) {
        .local_ref => |l| {
            try emitFlagName(w, f, l.slot);
            try w.writeAll(" = false;");
        },
        .field => |fa| {
            try emitMoveClear(w, program, f, lbl, fa.base.*);
            const def = program.structs[fa.strukt];
            for (def.fields, 0..) |field, k| {
                if (k == fa.field or !types.needsDrop(field.ty, regOf(program))) continue;
                try w.writeAll(" rt.drop(&");
                try emitExpr(w, program, f, lbl, fa.base.*);
                try w.print(".f{d}_{s});", .{ k, field.name });
            }
        },
        else => {},
    }
}

pub fn emitOwned(w: *std.Io.Writer, program: tir.Program, f: tir.Function, lbl: *u32, e: tir.Expr) Error!void {
    if (moveRoot(program, f, e) == null) return emitExpr(w, program, f, lbl, e);

    const id = lbl.*;
    lbl.* += 1;
    try w.print("(m{d}: {{ ", .{id});
    try emitMoveClear(w, program, f, lbl, e);
    try w.print(" break :m{d} ", .{id});
    try emitExpr(w, program, f, lbl, e);
    try w.writeAll("; })");
}

pub const Moves = struct {
    id: ?u32 = null,
};

pub fn beginMoves(w: *std.Io.Writer, program: tir.Program, f: tir.Function, lbl: *u32, args: []const tir.Expr) Error!Moves {
    var any = false;
    for (args) |arg| {
        if (moveRoot(program, f, arg) != null) any = true;
    }
    if (!any) return .{};

    const id = lbl.*;
    lbl.* += 1;
    try w.print("(m{d}: {{ ", .{id});
    for (args, 0..) |arg, i| {
        try w.print("const a{d}_{d} = ", .{ id, i });
        try emitExpr(w, program, f, lbl, arg);
        try w.writeAll("; ");
    }
    for (args) |arg| {
        if (moveRoot(program, f, arg) == null) continue;
        try emitMoveClear(w, program, f, lbl, arg);
        try w.writeAll(" ");
    }
    try w.print("break :m{d} ", .{id});
    return .{ .id = id };
}

pub fn emitArg(w: *std.Io.Writer, program: tir.Program, f: tir.Function, lbl: *u32, moves: Moves, args: []const tir.Expr, i: usize) Error!void {
    if (moves.id) |id| return w.print("a{d}_{d}", .{ id, i });
    try emitExpr(w, program, f, lbl, args[i]);
}

pub fn endMoves(w: *std.Io.Writer, moves: Moves) Error!void {
    if (moves.id != null) try w.writeAll("; })");
}

fn emitReceiver(
    w: *std.Io.Writer,
    program: tir.Program,
    f: tir.Function,
    lbl: *u32,
    e: tir.Expr,
) Error!void {
    if (e.typeOf() == .ref) {
        try emitExpr(w, program, f, lbl, e);
        return;
    }
    try w.writeAll("&");
    try emitExpr(w, program, f, lbl, e);
}

pub fn emitExpr(w: *std.Io.Writer, program: tir.Program, f: tir.Function, lbl: *u32, expr: tir.Expr) Error!void {
    switch (expr) {
        .string_const => |s| try emitZigString(w, s.value),

        .int_const => |i| try w.print("@as(i64, {d})", .{i.value}),

        .bool_const => |b| try w.writeAll(if (b.value) "true" else "false"),

        .local_ref => |l| try emitLocalName(w, f, l.slot),

        .unary => |u| {
            try w.writeAll(switch (u.op) {
                .neg => "-(",
                .not => "!(",
            });
            try emitExpr(w, program, f, lbl, u.operand.*);
            try w.writeAll(")");
        },

        .binary => |b| switch (b.op) {
            .div, .rem => {
                try w.print("(try {s}(", .{binOpText(b.op)});
                try emitExpr(w, program, f, lbl, b.lhs.*);
                try w.writeAll(", ");
                try emitExpr(w, program, f, lbl, b.rhs.*);
                try w.writeAll("))");
            },
            else => {
                try w.writeAll("(");
                try emitExpr(w, program, f, lbl, b.lhs.*);
                try w.print(" {s} ", .{binOpText(b.op)});
                try emitExpr(w, program, f, lbl, b.rhs.*);
                try w.writeAll(")");
            },
        },

        .call_builtin => |c| switch (c.builtin) {
            .read_line => {
                try w.writeAll("(try rt.readLine(");
                try emitExpr(w, program, f, lbl, c.args[0]);
                try w.writeAll("))");
            },
            .print_line => {
                const arg_ty = if (c.args.len == 1) c.args[0].typeOf() else types.Type.void;
                const is_string = arg_ty == .string or (arg_ty == .ref and arg_ty.ref.target.* == .string);
                const fn_name = if (c.args.len != 1)
                    "printLine"
                else switch (arg_ty) {
                    .int => "printLineInt",
                    .bool => "printLineBool",
                    else => if (is_string) "printLineString" else "printLine",
                };
                try w.print("(try rt.{s}(", .{fn_name});
                for (c.args, 0..) |arg, i| {
                    if (i > 0) try w.writeAll(", ");
                    if (is_string and arg.typeOf() != .ref) try w.writeAll("&");
                    try emitExpr(w, program, f, lbl, arg);
                }
                try w.writeAll("))");
            },
        },

        .call_function => |c| {
            const moves = try beginMoves(w, program, f, lbl, c.args);
            try w.print("(try {s}{s}(", .{ prefix, program.functions[c.target].name });
            for (c.args, 0..) |_, i| {
                if (i > 0) try w.writeAll(", ");
                try emitArg(w, program, f, lbl, moves, c.args, i);
            }
            try w.writeAll("))");
            try endMoves(w, moves);
        },

        .struct_lit => |s| {
            const def = program.structs[s.strukt];
            const moves = try beginMoves(w, program, f, lbl, s.fields);
            try w.print("S{d}_{s}{{ ", .{ s.strukt, def.name });
            for (s.fields, 0..) |_, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print(".f{d}_{s} = ", .{ i, def.fields[i].name });
                try emitArg(w, program, f, lbl, moves, s.fields, i);
            }
            try w.writeAll(" }");
            try endMoves(w, moves);
        },

        .field => |fa| {
            try emitExpr(w, program, f, lbl, fa.base.*);
            try w.print(".f{d}_{s}", .{ fa.field, program.structs[fa.strukt].fields[fa.field].name });
        },

        .array_lit => |a| {
            const moves = try beginMoves(w, program, f, lbl, a.elems);
            try w.print("[{d}]", .{a.elems.len});
            try emitType(w, program, a.ty.array.elem.*);
            try w.writeAll("{ ");
            for (a.elems, 0..) |_, i| {
                if (i > 0) try w.writeAll(", ");
                try emitArg(w, program, f, lbl, moves, a.elems, i);
            }
            try w.writeAll(" }");
            try endMoves(w, moves);
        },

        .index => |x| {
            try emitExpr(w, program, f, lbl, x.base.*);
            try w.print("[try rt.index({d}, ", .{x.base.typeOf().array.len});
            try emitExpr(w, program, f, lbl, x.index.*);
            try w.writeAll(")]");
        },

        .enum_lit => |lit| {
            const def = program.enums[lit.enumeration];
            const variant = def.variants[lit.variant];
            const moves = try beginMoves(w, program, f, lbl, lit.payload);
            try w.print("E{d}_{s}{{ .v{d}_{s} = ", .{ lit.enumeration, def.name, lit.variant, variant.name });
            if (lit.payload.len == 0) {
                try w.writeAll("{}");
            } else {
                try w.writeAll(".{ ");
                for (lit.payload, 0..) |_, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print(".f{d} = ", .{i});
                    try emitArg(w, program, f, lbl, moves, lit.payload, i);
                }
                try w.writeAll(" }");
            }
            try w.writeAll(" }");
            try endMoves(w, moves);
        },

        .borrow => |b| {
            try w.writeAll("&(");
            try emitExpr(w, program, f, lbl, b.operand.*);
            try w.writeAll(")");
        },

        .deref => |d| {
            try w.writeAll("(");
            try emitExpr(w, program, f, lbl, d.operand.*);
            try w.writeAll(").*");
        },

        .vec_op => |v| {
            switch (v.op) {
                .new => {
                    try w.writeAll("rt.Vec(");
                    try emitType(w, program, v.ty.vec.elem.*);
                    try w.writeAll(").init(");
                    try emitExpr(w, program, f, lbl, v.args[0]);
                    try w.writeAll(")");
                },
                .len, .str_len => {
                    try w.writeAll("(");
                    try emitReceiver(w, program, f, lbl, v.args[0]);
                    try w.writeAll(").len()");
                },
                .str_new => {
                    try w.writeAll("rt.String.init(");
                    try emitExpr(w, program, f, lbl, v.args[0]);
                    try w.writeAll(")");
                },
                .str_push, .str_push_int => {
                    try w.writeAll("(try (");
                    try emitReceiver(w, program, f, lbl, v.args[0]);
                    try w.print(").{s}(", .{if (v.op == .str_push) "push" else "pushInt"});
                    try emitExpr(w, program, f, lbl, v.args[1]);
                    try w.writeAll("))");
                },
                .get => {
                    const by_ref = v.ty == .ref;
                    try w.writeAll("(try (");
                    try emitReceiver(w, program, f, lbl, v.args[0]);
                    try w.print(").{s}(", .{if (by_ref) "ref" else "get"});
                    try emitExpr(w, program, f, lbl, v.args[1]);
                    try w.writeAll("))");
                },
                .push, .set => {
                    const rest = v.args[1..];
                    const moves = try beginMoves(w, program, f, lbl, rest);
                    try w.writeAll("(try (");
                    try emitReceiver(w, program, f, lbl, v.args[0]);
                    try w.print(").{s}(", .{if (v.op == .push) "push" else "set"});
                    for (rest, 0..) |_, i| {
                        if (i > 0) try w.writeAll(", ");
                        try emitArg(w, program, f, lbl, moves, rest, i);
                    }
                    try w.writeAll("))");
                    try endMoves(w, moves);
                },
            }
        },

        .try_unwrap => |t| {
            const src = program.enums[t.source_enum];
            const ret = program.enums[t.ret_enum];
            const id = lbl.*;
            lbl.* += 1;

            try w.print("b{d}: {{\n", .{id});
            try indent(w, 3);
            try w.writeAll("switch (");
            try emitOwned(w, program, f, lbl, t.operand.*);
            try w.writeAll(") {\n");

            try indent(w, 4);
            try w.print(".v{d}_{s} => |__t| break :b{d} __t.f0,\n", .{
                t.ok_variant,
                src.variants[t.ok_variant].name,
                id,
            });

            try indent(w, 4);
            const err_payload = src.variants[t.err_variant].payload.len;
            if (err_payload == 0) {
                try w.print(".v{d}_{s} => return E{d}_{s}{{ .v{d}_{s} = {{}} }},\n", .{
                    t.err_variant,
                    src.variants[t.err_variant].name,
                    t.ret_enum,
                    ret.name,
                    t.err_variant,
                    ret.variants[t.err_variant].name,
                });
            } else {
                try w.print(".v{d}_{s} => |__e| return E{d}_{s}{{ .v{d}_{s} = __e }},\n", .{
                    t.err_variant,
                    src.variants[t.err_variant].name,
                    t.ret_enum,
                    ret.name,
                    t.err_variant,
                    ret.variants[t.err_variant].name,
                });
            }

            try indent(w, 3);
            try w.writeAll("}\n    }");
        },

        .match => |m| try emitMatch(w, program, f, lbl, m),

        .if_expr => |node| {
            const is_void = node.ty == .void or node.ty == .invalid;

            try w.writeAll("if (");
            try emitExpr(w, program, f, lbl, node.cond.*);
            try w.writeAll(") ");

            if (is_void) {
                try emitVoidBlock(w, program, f, lbl, node.then_block);
                if (node.else_block) |b| {
                    try w.writeAll(" else ");
                    try emitVoidBlock(w, program, f, lbl, b);
                }
            } else {
                try emitValueBlock(w, program, f, lbl, node.then_block);
                try w.writeAll(" else ");
                if (node.else_block) |b| {
                    try emitValueBlock(w, program, f, lbl, b);
                } else {
                    try w.writeAll("unreachable");
                }
            }
        },

        .while_expr => |node| {
            if (node.cond_temps.len == 0) {
                try w.writeAll("while (");
                try emitExpr(w, program, f, lbl, node.cond.*);
                try w.writeAll(") ");
                try emitVoidBlock(w, program, f, lbl, node.body);
                return;
            }

            try w.writeAll("while (true) {\n");
            try emitBlockBody(w, program, f, lbl, .{ .stmts = node.cond_temps, .result = null }, 3);
            try indent(w, 3);
            try w.writeAll("if (!(");
            try emitExpr(w, program, f, lbl, node.cond.*);
            try w.writeAll(")) break;\n");
            try emitBlockBody(w, program, f, lbl, node.body, 3);
            try indent(w, 1);
            try w.writeAll("}");
        },
    }
}

pub fn emitZigString(w: *std.Io.Writer, value: []const u8) Error!void {
    try w.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            '\r' => try w.writeAll("\\r"),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(c),
            else => try w.print("\\x{x:0>2}", .{c}),
        }
    }
    try w.writeByte('"');
}

pub fn binOpText(op: tir.BinOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "rt.div",
        .rem => "rt.rem",
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .gt => ">",
        .le => "<=",
        .ge => ">=",
        .logical_and => "and",
        .logical_or => "or",
    };
}

pub fn emitMatch(w: *std.Io.Writer, program: tir.Program, f: tir.Function, lbl: *u32, m: tir.Match) Error!void {
    const def = program.enums[m.enumeration];
    const is_void = m.ty == .void or m.ty == .invalid;

    try w.writeAll("switch (");
    try emitExpr(w, program, f, lbl, m.scrutinee.*);
    try w.writeAll(") {\n");

    for (m.arms) |arm| {
        try w.writeAll("        ");

        if (arm.variant) |vi| {
            try w.print(".v{d}_{s}", .{ vi, def.variants[vi].name });
        } else {
            try w.writeAll("else");
        }

        const captures = arm.variant != null and def.variants[arm.variant.?].payload.len > 0;
        if (captures) {
            try w.writeAll(if (m.by_ref) " => |*__p| " else " => |__p| ");
        } else {
            try w.writeAll(" => ");
        }

        if (is_void) {
            try w.writeAll("{\n");
        } else {
            try w.writeAll("blk: {\n");
        }

        if (captures and arm.bindings.len == 0) try w.writeAll("            _ = __p;\n");

        var takes_payload = false;
        for (arm.bindings, 0..) |slot, i| {
            const local = f.locals[slot];
            const owned = !m.by_ref and types.needsDrop(local.ty, regOf(program));
            if (owned) takes_payload = true;
            try indent(w, 3);
            try w.writeAll(if (owned) "var " else "const ");
            try emitLocalName(w, f, slot);
            try w.print(" = {s}__p.f{d};\n", .{ if (m.by_ref and local.ty == .ref) "&" else "", i });
            if (owned) try emitOwnedGuard(w, program, f, slot, 3);
            if (!local.used) {
                try indent(w, 3);
                try w.writeAll("_ = ");
                try emitLocalName(w, f, slot);
                try w.writeAll(";\n");
            }
        }

        if (takes_payload and moveRoot(program, f, m.scrutinee.*) != null) {
            try indent(w, 3);
            try emitMoveClear(w, program, f, lbl, m.scrutinee.*);
            try w.writeAll("\n");
        }

        try emitBlockBody(w, program, f, lbl, .{ .stmts = arm.temps, .result = null }, 3);

        try indent(w, 3);
        if (!is_void) try w.writeAll("break :blk ");
        try emitOwned(w, program, f, lbl, arm.body);
        try w.writeAll(";\n        },\n");
    }

    try w.writeAll("    }");
}

pub fn emitLocalName(w: *std.Io.Writer, f: tir.Function, slot: u32) Error!void {
    try w.print("v{d}_{s}", .{ slot, f.locals[slot].name });
}
