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
const ownership = @import("../sema/ownership.zig");

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
    try ownership.check(gpa, program, &d);

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

test "emits division and remainder through checked runtime helpers" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn main() {\n    println(7 / 2)\n    println(7 % 2)\n}\n");
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "(try rt.div(@as(i64, 7), @as(i64, 2)))") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(try rt.rem(@as(i64, 7), @as(i64, 2)))") != null);
}

test "array indexing goes through the runtime bounds check" {
    const gpa = testing.allocator;
    const out = try emitText(gpa, "fn main() {\n    let a = [1, 2, 3]\n    let i = 1\n    println(a[i])\n}\n");
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "v0_a[try rt.index(3, v1_i)]") != null);
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

test "a diverging branch in a value if emits no block label" {
    const gpa = testing.allocator;
    const out = try emitText(gpa,
        \\fn pick(n: Int) -> Int {
        \\    if n > 0 {
        \\        return 1
        \\    } else {
        \\        2
        \\    }
        \\}
        \\fn main() {
        \\    println(pick(1))
        \\}
        \\
    );
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "if ((v0_n > @as(i64, 0))) {\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "break :b0 {}") == null);
    try testing.expect(std.mem.indexOf(u8, out, "break :b0 @as(i64, 2)") != null);
}

test "owned locals are released through the runtime drop helper" {
    const gpa = testing.allocator;
    const out = try emitText(gpa,
        \\fn main(alloc: Allocator) {
        \\    let v: Vec<Int> = Vec.new(alloc)
        \\    v.push(1)
        \\}
        \\
    );
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "defer rt.drop(&v1_v);") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".deinit()") == null);
}

test "aggregate deinit releases fields through the runtime drop helper" {
    const gpa = testing.allocator;
    const out = try emitText(gpa,
        \\struct Bag {
        \\    items: [String; 2]
        \\}
        \\enum Holder {
        \\    Some(Vec<Int>)
        \\    None
        \\}
        \\fn main() {
        \\}
        \\
    );
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "rt.drop(&self.f0_items);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "rt.drop(&payload.f0);") != null);
}

test "a moved local gets a live flag that guards its release" {
    const gpa = testing.allocator;
    const out = try emitText(gpa,
        \\fn consume(v: Vec<Int>) {
        \\    println(v.len())
        \\}
        \\fn main(alloc: Allocator) {
        \\    let v: Vec<Int> = Vec.new(alloc)
        \\    if v.len() > 5 {
        \\        consume(v)
        \\    }
        \\}
        \\
    );
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "var v1_v_live = true;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "defer if (v1_v_live) rt.drop(&v1_v);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const a0_0 = v1_v; v1_v_live = false; break :m0 (try rc_consume(a0_0));") != null);
}

test "moving one field releases its owning siblings" {
    const gpa = testing.allocator;
    const out = try emitText(gpa,
        \\struct Bag {
        \\    a: Vec<Int>
        \\    n: Int
        \\    b: Vec<Int>
        \\}
        \\fn consume(v: Vec<Int>) {
        \\    println(v.len())
        \\}
        \\fn main(alloc: Allocator) {
        \\    let bag = Bag { a: Vec.new(alloc), n: 1, b: Vec.new(alloc) }
        \\    consume(bag.a)
        \\}
        \\
    );
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "v3_bag_live = false; rt.drop(&v3_bag.f2_b); break :m1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "rt.drop(&v3_bag.f1_n)") == null);
}

test "reassigning an owned local releases the old value first" {
    const gpa = testing.allocator;
    const out = try emitText(gpa,
        \\fn make(alloc: Allocator) -> Vec<Int> {
        \\    Vec.new(alloc)
        \\}
        \\fn main(alloc: Allocator) {
        \\    let mut v = make(alloc)
        \\    v = make(alloc)
        \\}
        \\
    );
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "{ const __new = (try rc_make(v0_alloc)); rt.drop(&v1_v); v1_v = __new; }") != null);
}

test "an arm that yields its owned binding clears the binding flag" {
    const gpa = testing.allocator;
    const out = try emitText(gpa,
        \\enum Holder {
        \\    Some(Vec<Int>)
        \\    None
        \\}
        \\fn unwrap(alloc: Allocator, h: Holder) -> Vec<Int> {
        \\    match h {
        \\        Some(v) => v
        \\        None => Vec.new(alloc)
        \\    }
        \\}
        \\fn main() {
        \\}
        \\
    );
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "defer if (v2_v_live) rt.drop(&v2_v);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "break :blk (m0: { v2_v_live = false; break :m0 v2_v; });") != null);
}
