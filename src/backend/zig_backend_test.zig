const std = @import("std");
const tir = @import("../ir/tir.zig");
const types = @import("../sema/types.zig");
const runtime = @import("runtime.zig");
const zig_types = @import("zig/types.zig");
const zig_stmt = @import("zig/stmt.zig");
const zig_expr = @import("zig/expr.zig");
const prefix = zig_types.prefix;
const Error = zig_types.Error;
const emitType = zig_types.emitType;
const emitBlockBody = zig_stmt.emitBlockBody;
const emitExpr = zig_expr.emitExpr;
const emitLocalName = zig_expr.emitLocalName;
const backend = @import("zig_backend.zig");

const emit = backend.emit;

const testing = std.testing;

const source = @import("../support/source.zig");
const diagnostics = @import("../support/diagnostics.zig");
const lexer = @import("../syntax/lexer.zig");
const parser = @import("../syntax/parser.zig");
const resolve = @import("../sema/resolve.zig");
const lower = @import("../sema/lower.zig");

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
    const text = @embedFile("zig_backend.zig");
    const cut = std.mem.indexOf(u8, text, "const testing = std.testing;") orelse text.len;
    const impl = text[0..cut];

    try testing.expect(std.mem.indexOf(u8, impl, "@import(\"../syntax/ast.zig\")") == null);
    try testing.expect(std.mem.indexOf(u8, impl, "@import(\"../syntax/parser.zig\")") == null);
    try testing.expect(std.mem.indexOf(u8, impl, "@import(\"../syntax/lexer.zig\")") == null);
    try testing.expect(std.mem.indexOf(u8, impl, "@import(\"../syntax/token.zig\")") == null);
    try testing.expect(std.mem.indexOf(u8, impl, "@import(\"../ir/tir.zig\")") != null);
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
