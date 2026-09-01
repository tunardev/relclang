const std = @import("std");
const tir = @import("../tir.zig");
const types = @import("../types.zig");
const runtime = @import("runtime.zig");

const prefix = "rc_";

const Error = error{ OutOfMemory, WriteFailed };

pub fn emit(arena: std.mem.Allocator, program: tir.Program) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("const std = @import(\"std\");\n");
    try w.print("const rt = @import(\"{s}\");\n\n", .{runtime.file_name});

    for (program.enums, 0..) |def, index| {
        try w.print("const E{d}_{s} = union(enum) {{\n", .{ index, def.name });
        for (def.variants, 0..) |variant, vi| {
            try w.print("    v{d}_{s}: ", .{ vi, variant.name });
            if (variant.payload.len == 0) {
                try w.writeAll("void");
            } else {
                try w.writeAll("struct { ");
                for (variant.payload, 0..) |ty, fi| {
                    if (fi > 0) try w.writeAll(", ");
                    try w.print("f{d}: ", .{fi});
                    try emitType(w, program, ty);
                }
                try w.writeAll(" }");
            }
            try w.writeAll(",\n");
        }
        try w.writeAll("};\n\n");
    }

    for (program.structs, 0..) |def, index| {
        try w.print("const S{d}_{s} = struct {{\n", .{ index, def.name });
        for (def.fields, 0..) |field, i| {
            try w.print("    f{d}_{s}: ", .{ i, field.name });
            try emitType(w, program, field.ty);
            try w.writeAll(",\n");
        }
        try w.writeAll("};\n\n");
    }

    var entry: ?[]const u8 = null;

    for (program.functions) |f| {
        try w.print("fn {s}{s}(", .{ prefix, f.name });
        for (0..f.param_count) |i| {
            if (i > 0) try w.writeAll(", ");
            try emitLocalName(w, f, @intCast(i));
            try w.writeAll(": ");
            try emitType(w, program, f.locals[i].ty);
        }
        try w.writeAll(") rt.Error!");
        try emitType(w, program, f.ret);
        try w.writeAll(" {\n");
        var lbl: u32 = 0;
        try emitBlockBody(w, program, f, &lbl, f.body, 1);
        if (f.body.result) |result| {
            try w.writeAll("    return ");
            try emitExpr(w, program, f, &lbl, result.*);
            try w.writeAll(";\n");
        }
        try w.writeAll("}\n\n");

        if (f.is_entry) entry = f.name;
    }

    if (entry) |name| {
        try w.writeAll("pub fn main(init: std.process.Init) !void {\n");
        try w.writeAll("    rt.init(init.io);\n");
        try w.print("    try {s}{s}();\n", .{ prefix, name });
        try w.writeAll("}\n");
    }

    return aw.written();
}

fn emitType(w: *std.Io.Writer, program: tir.Program, ty: types.Type) Error!void {
    switch (ty) {
        .void, .invalid => try w.writeAll("void"),
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

fn indent(w: *std.Io.Writer, level: usize) Error!void {
    try w.splatByteAll(' ', level * 4);
}

fn emitBlockBody(
    w: *std.Io.Writer,
    program: tir.Program,
    f: tir.Function,
    lbl: *u32,
    block: tir.Block,
    level: usize,
) Error!void {
    for (block.stmts) |stmt| try emitStmt(w, program, f, lbl, stmt, level);
}

fn isBlockForm(e: tir.Expr) bool {
    return switch (e) {
        .match => |m| m.ty == .void or m.ty == .invalid,
        .if_expr => |i| i.ty == .void or i.ty == .invalid,
        .while_expr => true,
        else => false,
    };
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
        .assign => |a| {
            try indent(w, level);
            try emitExpr(w, program, f, lbl, a.target);
            try w.writeAll(" = ");
            try emitExpr(w, program, f, lbl, a.value);
            try w.writeAll(";\n");
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

fn emitValueBlock(
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

fn emitVoidBlock(
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

fn emitLocalName(w: *std.Io.Writer, f: tir.Function, slot: u32) Error!void {
    try w.print("v{d}_{s}", .{ slot, f.locals[slot].name });
}

fn binOpText(op: tir.BinOp) []const u8 {
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

fn emitExpr(w: *std.Io.Writer, program: tir.Program, f: tir.Function, lbl: *u32, expr: tir.Expr) Error!void {
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

fn emitMatch(w: *std.Io.Writer, program: tir.Program, f: tir.Function, lbl: *u32, m: tir.Match) Error!void {
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

fn emitZigString(w: *std.Io.Writer, value: []const u8) Error!void {
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

const testing = std.testing;

const source = @import("../source.zig");
const diagnostics = @import("../diagnostics.zig");
const lexer = @import("../lexer.zig");
const parser = @import("../parser.zig");
const resolve = @import("../resolve.zig");
const lower = @import("../lower.zig");

fn emitText(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    const toks = try lexer.tokenize(arena, file, &d);
    const parsed = try parser.parse(arena, toks, &d);
    var symbols = try resolve.run(arena, gpa, parsed, &d);
    defer symbols.deinit();
    const program = try lower.run(arena, gpa, parsed, &symbols, &d);

    const out = try emit(arena, program);
    return gpa.dupe(u8, out);
}

test "emits a runnable hello world" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn main() {\n    println(\"Hello, Relastic!\")\n}\n");
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "@import(\"relastic_rt.zig\")") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fn rc_main() rt.Error!void") != null);
    try testing.expect(std.mem.indexOf(u8, out, "rt.printLine(\"Hello, Relastic!\")") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn main(init: std.process.Init) !void") != null);
    try testing.expect(std.mem.indexOf(u8, out, "try rc_main();") != null);
}

test "mangles every relastic symbol" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn helper() {\n}\nfn main() {\n    helper()\n}\n");
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "fn rc_helper()") != null);
    try testing.expect(std.mem.indexOf(u8, out, "rc_helper()") != null);
}

test "a program without main emits no zig entry point" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn helper() {\n}\n");
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "fn rc_helper()") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn main") == null);
}

test "escapes special characters for zig" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn main() {\n    println(\"a\\nb\\\"c\\\\d\")\n}\n");
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"a\\nb\\\"c\\\\d\"") != null);
}

test "escapes non printable bytes as hex" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn main() {\n    println(\"a\\0b\")\n}\n");
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\\x00") != null);
}

test "emits no comments" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn main() {\n    println(\"hi\")\n}\n");
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "//") == null);
}

test "backend never imports the syntax layer" {
    const text = @embedFile("zig.zig");
    const cut = std.mem.indexOf(u8, text, "const testing = std.testing;") orelse text.len;
    const impl = text[0..cut];

    try testing.expect(std.mem.indexOf(u8, impl, "@import(\"../ast.zig\")") == null);
    try testing.expect(std.mem.indexOf(u8, impl, "@import(\"../parser.zig\")") == null);
    try testing.expect(std.mem.indexOf(u8, impl, "@import(\"../lexer.zig\")") == null);
    try testing.expect(std.mem.indexOf(u8, impl, "@import(\"../token.zig\")") == null);
    try testing.expect(std.mem.indexOf(u8, impl, "@import(\"../tir.zig\")") != null);
}

test "emits locals with slot prefixed names" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn main() {\n    let x = 10\n    println(x)\n}\n");
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "const v0_x = @as(i64, 10);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "rt.printLineInt(v0_x)") != null);
}

test "discards only unused locals" {
    const gpa = testing.allocator;

    const unused = try emitText(gpa, "fn main() {\n    let x = 1\n}\n");
    defer gpa.free(unused);
    try testing.expect(std.mem.indexOf(u8, unused, "_ = v0_x;") != null);

    const used = try emitText(gpa, "fn main() {\n    let x = 1\n    println(x)\n}\n");
    defer gpa.free(used);
    try testing.expect(std.mem.indexOf(u8, used, "_ = v0_x;") == null);
}

test "dispatches print on the argument type" {
    const gpa = testing.allocator;

    const as_int = try emitText(gpa, "fn main() {\n    println(1)\n}\n");
    defer gpa.free(as_int);
    try testing.expect(std.mem.indexOf(u8, as_int, "rt.printLineInt(") != null);

    const as_str = try emitText(gpa, "fn main() {\n    println(\"a\")\n}\n");
    defer gpa.free(as_str);
    try testing.expect(std.mem.indexOf(u8, as_str, "rt.printLine(") != null);
    try testing.expect(std.mem.indexOf(u8, as_str, "printLineInt") == null);
}

test "emits division and remainder as builtins that trap" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn main() {\n    println(7 / 2)\n    println(7 % 2)\n}\n");
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "@divTrunc(") != null);
    try testing.expect(std.mem.indexOf(u8, out, "@rem(") != null);
}

test "parenthesises binary operands to preserve precedence" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn main() {\n    println((2 + 3) * 4)\n}\n");
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "((@as(i64, 2) + @as(i64, 3)) * @as(i64, 4))") != null);
}

test "emits negation" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn main() {\n    println(-5)\n}\n");
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "@as(i64, -5)") != null);
}
