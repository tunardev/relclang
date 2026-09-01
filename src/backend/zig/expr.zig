const std = @import("std");
const tir = @import("../../ir/tir.zig");
const types = @import("../../sema/types.zig");
const runtime = @import("../runtime.zig");

pub const prefix = "rc_";
pub const Error = error{ OutOfMemory, WriteFailed };

const emitType = @import("types.zig").emitType;
const emitValueBlock = @import("stmt.zig").emitValueBlock;
const emitVoidBlock = @import("stmt.zig").emitVoidBlock;
const indent = @import("stmt.zig").indent;

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
                try w.print("{s}(", .{binOpText(b.op)});
                try emitExpr(w, program, f, lbl, b.lhs.*);
                try w.writeAll(", ");
                try emitExpr(w, program, f, lbl, b.rhs.*);
                try w.writeAll(")");
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
            .print_line => {
                const fn_name = if (c.args.len != 1)
                    "printLine"
                else switch (c.args[0].typeOf()) {
                    .int => "printLineInt",
                    .bool => "printLineBool",
                    else => "printLine",
                };
                try w.print("(try rt.{s}(", .{fn_name});
                for (c.args, 0..) |arg, i| {
                    if (i > 0) try w.writeAll(", ");
                    try emitExpr(w, program, f, lbl, arg);
                }
                try w.writeAll("))");
            },
        },

        .call_function => |c| {
            try w.print("(try {s}{s}(", .{ prefix, program.functions[c.target].name });
            for (c.args, 0..) |arg, i| {
                if (i > 0) try w.writeAll(", ");
                try emitExpr(w, program, f, lbl, arg);
            }
            try w.writeAll("))");
        },

        .struct_lit => |s| {
            const def = program.structs[s.strukt];
            try w.print("S{d}_{s}{{ ", .{ s.strukt, def.name });
            for (s.fields, 0..) |value, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print(".f{d}_{s} = ", .{ i, def.fields[i].name });
                try emitExpr(w, program, f, lbl, value);
            }
            try w.writeAll(" }");
        },

        .field => |fa| {
            try emitExpr(w, program, f, lbl, fa.base.*);
            try w.print(".f{d}_{s}", .{ fa.field, program.structs[fa.strukt].fields[fa.field].name });
        },

        .array_lit => |a| {
            try w.print("[{d}]", .{a.elems.len});
            try emitType(w, program, a.ty.array.elem.*);
            try w.writeAll("{ ");
            for (a.elems, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                try emitExpr(w, program, f, lbl, e);
            }
            try w.writeAll(" }");
        },

        .index => |x| {
            try emitExpr(w, program, f, lbl, x.base.*);
            try w.writeAll("[@as(usize, @intCast(");
            try emitExpr(w, program, f, lbl, x.index.*);
            try w.writeAll("))]");
        },

        .enum_lit => |lit| {
            const def = program.enums[lit.enumeration];
            const variant = def.variants[lit.variant];
            try w.print("E{d}_{s}{{ .v{d}_{s} = ", .{ lit.enumeration, def.name, lit.variant, variant.name });
            if (lit.payload.len == 0) {
                try w.writeAll("{}");
            } else {
                try w.writeAll(".{ ");
                for (lit.payload, 0..) |value, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print(".f{d} = ", .{i});
                    try emitExpr(w, program, f, lbl, value);
                }
                try w.writeAll(" }");
            }
            try w.writeAll(" }");
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

        .try_unwrap => |t| {
            const src = program.enums[t.source_enum];
            const ret = program.enums[t.ret_enum];
            const id = lbl.*;
            lbl.* += 1;

            try w.print("b{d}: {{\n", .{id});
            try indent(w, 3);
            try w.writeAll("switch (");
            try emitExpr(w, program, f, lbl, t.operand.*);
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
            try w.writeAll("while (");
            try emitExpr(w, program, f, lbl, node.cond.*);
            try w.writeAll(") ");
            try emitVoidBlock(w, program, f, lbl, node.body);
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
        .div => "@divTrunc",
        .rem => "@rem",
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
        if (captures) try w.writeAll(" => |__p| ") else try w.writeAll(" => ");

        if (is_void) {
            try w.writeAll("{\n");
        } else {
            try w.writeAll("blk: {\n");
        }

        if (captures and arm.bindings.len == 0) try w.writeAll("            _ = __p;\n");

        for (arm.bindings, 0..) |slot, i| {
            try w.writeAll("            const ");
            try emitLocalName(w, f, slot);
            try w.print(" = __p.f{d};\n", .{i});
            if (!f.locals[slot].used) {
                try w.writeAll("            _ = ");
                try emitLocalName(w, f, slot);
                try w.writeAll(";\n");
            }
        }

        try w.writeAll("            ");
        if (!is_void) try w.writeAll("break :blk ");
        try emitExpr(w, program, f, lbl, arm.body);
        try w.writeAll(";\n        },\n");
    }

    try w.writeAll("    }");
}

pub fn emitLocalName(w: *std.Io.Writer, f: tir.Function, slot: u32) Error!void {
    try w.print("v{d}_{s}", .{ slot, f.locals[slot].name });
}
