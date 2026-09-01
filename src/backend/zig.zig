const std = @import("std");
const tir = @import("../tir.zig");
const runtime = @import("runtime.zig");

const prefix = "rc_";

const Error = error{ OutOfMemory, WriteFailed };

pub fn emit(arena: std.mem.Allocator, program: tir.Program) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("const std = @import(\"std\");\n");
    try w.print("const rt = @import(\"{s}\");\n\n", .{runtime.file_name});

    var entry: ?[]const u8 = null;

    for (program.functions) |f| {
        try w.print("fn {s}{s}() rt.Error!void {{\n", .{ prefix, f.name });
        for (f.body.stmts) |stmt| try emitStmt(w, program, f, stmt);
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

fn emitStmt(w: *std.Io.Writer, program: tir.Program, f: tir.Function, stmt: tir.Stmt) Error!void {
    switch (stmt) {
        .expr => |e| {
            try w.writeAll("    ");
            try emitExpr(w, program, f, e);
            try w.writeAll(";\n");
        },
        .let => |l| {
            try w.writeAll("    const ");
            try emitLocalName(w, f, l.slot);
            try w.writeAll(" = ");
            try emitExpr(w, program, f, l.init);
            try w.writeAll(";\n");
            if (!f.locals[l.slot].used) {
                try w.writeAll("    _ = ");
                try emitLocalName(w, f, l.slot);
                try w.writeAll(";\n");
            }
        },
    }
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
    };
}

fn emitExpr(w: *std.Io.Writer, program: tir.Program, f: tir.Function, expr: tir.Expr) Error!void {
    switch (expr) {
        .string_const => |s| try emitZigString(w, s.value),

        .int_const => |i| try w.print("@as(i64, {d})", .{i.value}),

        .local_ref => |l| try emitLocalName(w, f, l.slot),

        .unary => |u| {
            try w.writeAll("-(");
            try emitExpr(w, program, f, u.operand.*);
            try w.writeAll(")");
        },

        .binary => |b| switch (b.op) {
            .div, .rem => {
                try w.print("{s}(", .{binOpText(b.op)});
                try emitExpr(w, program, f, b.lhs.*);
                try w.writeAll(", ");
                try emitExpr(w, program, f, b.rhs.*);
                try w.writeAll(")");
            },
            else => {
                try w.writeAll("(");
                try emitExpr(w, program, f, b.lhs.*);
                try w.print(" {s} ", .{binOpText(b.op)});
                try emitExpr(w, program, f, b.rhs.*);
                try w.writeAll(")");
            },
        },

        .call_builtin => |c| switch (c.builtin) {
            .print_line => {
                const fn_name = if (c.args.len == 1 and c.args[0].typeOf() == .int)
                    "printLineInt"
                else
                    "printLine";
                try w.print("try rt.{s}(", .{fn_name});
                for (c.args, 0..) |arg, i| {
                    if (i > 0) try w.writeAll(", ");
                    try emitExpr(w, program, f, arg);
                }
                try w.writeAll(")");
            },
        },

        .call_function => |c| {
            try w.print("try {s}{s}(", .{ prefix, program.functions[c.target].name });
            for (c.args, 0..) |arg, i| {
                if (i > 0) try w.writeAll(", ");
                try emitExpr(w, program, f, arg);
            }
            try w.writeAll(")");
        },
    }
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
    var symbols = try resolve.run(gpa, parsed, &d);
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
    try testing.expect(std.mem.indexOf(u8, out, "try rt.printLine(\"Hello, Relastic!\")") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn main(init: std.process.Init) !void") != null);
    try testing.expect(std.mem.indexOf(u8, out, "try rc_main();") != null);
}

test "mangles every relastic symbol" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn helper() {\n}\nfn main() {\n    helper()\n}\n");
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "fn rc_helper()") != null);
    try testing.expect(std.mem.indexOf(u8, out, "try rc_helper();") != null);
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
    try testing.expect(std.mem.indexOf(u8, out, "-(@as(i64, 5))") != null);
}
