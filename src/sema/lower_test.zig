const std = @import("std");
const source = @import("../support/source.zig");
const diagnostics = @import("../support/diagnostics.zig");
const lexer = @import("../syntax/lexer.zig");
const parser = @import("../syntax/parser.zig");
const resolve = @import("resolve.zig");
const tir = @import("../ir/tir.zig");
const types = @import("types.zig");

const run = @import("lower.zig").run;

const testing = std.testing;

const Lowered = struct {
    arena: std.heap.ArenaAllocator,
    diags: diagnostics.Diagnostics,
    symbols: resolve.SymbolTable,
    program: tir.Program,

    fn deinit(l: *Lowered) void {
        l.symbols.deinit();
        l.diags.deinit();
        l.arena.deinit();
    }

    fn has(l: Lowered, code: diagnostics.Code) bool {
        for (l.diags.list.items) |item| {
            if (item.code == code) return true;
        }
        return false;
    }
};

fn lowerText(gpa: std.mem.Allocator, text: []const u8) !Lowered {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    var d: diagnostics.Diagnostics = .init(gpa);
    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    const toks = try lexer.tokenize(arena_state.allocator(), file, &d);
    const parsed = try parser.parse(arena_state.allocator(), toks, &d);
    var symbols = try resolve.run(arena_state.allocator(), gpa, parsed, &d);
    const program = try run(arena_state.allocator(), gpa, parsed, &symbols, &d);
    return .{ .arena = arena_state, .diags = d, .symbols = symbols, .program = program };
}

test "lowers println to the print_line builtin" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(\"hi\")\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const f = l.program.functions[0];
    try testing.expect(f.is_entry);

    const call = f.body.stmts[0].expr.call_builtin;
    try testing.expectEqual(tir.Builtin.print_line, call.builtin);
    try testing.expectEqualStrings("hi", call.args[0].string_const.value);
}

test "only main is marked as the entry point" {
    var l = try lowerText(testing.allocator, "fn helper() {\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(!l.program.functions[0].is_entry);
    try testing.expect(l.program.functions[1].is_entry);
}

test "lowers a user function call" {
    var l = try lowerText(testing.allocator, "fn helper() {\n}\nfn main() {\n    helper()\n}\n");
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.program.functions[1].body.stmts[0].expr.call_function.target);
}

test "let allocates a slot and records its type" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x = 10\n    println(x)\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const f = l.program.functions[0];
    try testing.expectEqual(@as(usize, 1), f.locals.len);
    try testing.expectEqualStrings("x", f.locals[0].name);
    try testing.expectEqual(types.Type.int, f.locals[0].ty);
    try testing.expect(f.locals[0].used);

    const decl = f.body.stmts[0].let;
    try testing.expectEqual(@as(u32, 0), decl.slot);
    try testing.expectEqual(@as(i64, 10), decl.init.int_const.value);
}

test "slots increase in declaration order" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = 1\n    let b = 2\n    println(a + b)\n}\n");
    defer l.deinit();

    const f = l.program.functions[0];
    try testing.expectEqual(@as(u32, 0), f.body.stmts[0].let.slot);
    try testing.expectEqual(@as(u32, 1), f.body.stmts[1].let.slot);

    const sum = f.body.stmts[2].expr.call_builtin.args[0].binary;
    try testing.expectEqual(@as(u32, 0), sum.lhs.local_ref.slot);
    try testing.expectEqual(@as(u32, 1), sum.rhs.local_ref.slot);
}

test "an unused local is marked unused" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x = 1\n}\n");
    defer l.deinit();
    try testing.expect(!l.program.functions[0].locals[0].used);
}

test "precedence puts multiplication under addition" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(2 + 3 * 4)\n}\n");
    defer l.deinit();

    const top = l.program.functions[0].body.stmts[0].expr.call_builtin.args[0].binary;
    try testing.expectEqual(tir.BinOp.add, top.op);
    try testing.expectEqual(@as(i64, 2), top.lhs.int_const.value);
    try testing.expectEqual(tir.BinOp.mul, top.rhs.binary.op);
}

test "subtraction is left associative" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(10 - 3 - 2)\n}\n");
    defer l.deinit();

    const top = l.program.functions[0].body.stmts[0].expr.call_builtin.args[0].binary;
    try testing.expectEqual(tir.BinOp.sub, top.op);
    try testing.expectEqual(tir.BinOp.sub, top.lhs.binary.op);
    try testing.expectEqual(@as(i64, 2), top.rhs.int_const.value);
}

test "underscores are stripped from integer literals" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(1_000)\n}\n");
    defer l.deinit();
    try testing.expectEqual(@as(i64, 1000), l.program.functions[0].body.stmts[0].expr.call_builtin.args[0].int_const.value);
}

test "an annotation overrides the inferred type only when it agrees" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x: Int = 10\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    try testing.expectEqual(types.Type.int, l.program.functions[0].locals[0].ty);
}

test "unknown variable reports E0012" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(z)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unknown_variable));
}

test "duplicate binding reports E0011" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x = 1\n    let x = 2\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.duplicate_binding));
}

test "string arithmetic reports E0013" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(\"a\" + \"b\")\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.invalid_operand));
}

test "mixed operands report E0013" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let n = 1\n    println(n + \"x\")\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.invalid_operand));
}

test "an annotation mismatch reports E0008" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x: Str = 10\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "binding a void call reports E0013" {
    var l = try lowerText(testing.allocator, "fn helper() {\n}\nfn main() {\n    let x = helper()\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.invalid_operand));
}

test "an out of range literal reports E0014" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(99999999999999999999)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.integer_overflow));
}

test "the largest int literal is accepted" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(9223372036854775807)\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "unknown function reports E0004" {
    var l = try lowerText(testing.allocator, "fn main() {\n    nope(\"hi\")\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unknown_function));
}

test "a bad operand does not cascade into a second error" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(\"a\" + \"b\")\n}\n");
    defer l.deinit();
    try testing.expectEqual(@as(usize, 1), l.diags.list.items.len);
}

test "spans survive lowering" {
    const text = "fn main() {\n    println(\"hi\")\n}\n";
    var l = try lowerText(testing.allocator, text);
    defer l.deinit();
    const arg = l.program.functions[0].body.stmts[0].expr.call_builtin.args[0].string_const;
    try testing.expectEqualStrings("\"hi\"", text[arg.span.start..arg.span.end]);
}

test "parameters become the first locals" {
    var l = try lowerText(testing.allocator, "fn add(a: Int, b: Int) -> Int {\n    a + b\n}\nfn main() {\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const f = l.program.functions[0];
    try testing.expectEqual(@as(u32, 2), f.param_count);
    try testing.expectEqual(types.Type.int, f.ret);
    try testing.expectEqualStrings("a", f.locals[0].name);
    try testing.expectEqualStrings("b", f.locals[1].name);
}

test "the final expression becomes a return value" {
    var l = try lowerText(testing.allocator, "fn f() -> Int {\n    7\n}\nfn main() {\n}\n");
    defer l.deinit();

    try testing.expectEqual(@as(i64, 7), l.program.functions[0].body.result.?.int_const.value);
}

test "a void function has no return value statement" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(\"hi\")\n}\n");
    defer l.deinit();
    try testing.expect(l.program.functions[0].body.stmts[0] == .expr);
    try testing.expectEqual(types.Type.void, l.program.functions[0].ret);
}

test "a call takes its type from the signature" {
    var l = try lowerText(testing.allocator, "fn f() -> Int {\n    1\n}\nfn main() {\n    println(f())\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    const call = l.program.functions[1].body.stmts[0].expr.call_builtin.args[0].call_function;
    try testing.expectEqual(types.Type.int, call.ty);
}

test "a missing return value reports E0016" {
    var l = try lowerText(testing.allocator, "fn f() -> Int {\n    println(\"x\")\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.missing_return));
}

test "an empty body for a returning function reports E0016" {
    var l = try lowerText(testing.allocator, "fn f() -> Int {\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.missing_return));
}

test "an unused value reports E0015" {
    var l = try lowerText(testing.allocator, "fn main() {\n    1 + 2\n    println(\"x\")\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unused_value));
}

test "wrong argument count to a user function reports E0007" {
    var l = try lowerText(testing.allocator, "fn add(a: Int, b: Int) -> Int {\n    a + b\n}\nfn main() {\n    println(add(1))\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.wrong_arg_count));
}

test "wrong argument type to a user function reports E0008" {
    var l = try lowerText(testing.allocator, "fn add(a: Int, b: Int) -> Int {\n    a + b\n}\nfn main() {\n    println(add(1, \"x\"))\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "a duplicate parameter reports E0011" {
    var l = try lowerText(testing.allocator, "fn f(a: Int, a: Int) -> Int {\n    a\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.duplicate_binding));
}

test "a str parameter round trips" {
    var l = try lowerText(testing.allocator, "fn greet(name: Str) {\n    println(name)\n}\nfn main() {\n    greet(\"hi\")\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    try testing.expectEqual(types.Type.str, l.program.functions[0].locals[0].ty);
}

test "a struct literal fills fields in declaration order" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n    y: Int\n}\nfn main() {\n    let p = P { y: 2, x: 1 }\n    println(p.x)\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const lit = l.program.functions[0].body.stmts[0].let.init.struct_lit;
    try testing.expectEqual(@as(i64, 1), lit.fields[0].int_const.value);
    try testing.expectEqual(@as(i64, 2), lit.fields[1].int_const.value);
}

test "field access resolves to a slot index and type" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n    y: Str\n}\nfn main() {\n    let p = P { x: 1, y: \"a\" }\n    println(p.y)\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const access = l.program.functions[0].body.stmts[1].expr.call_builtin.args[0].field;
    try testing.expectEqual(@as(u32, 1), access.field);
    try testing.expect(types.Type.eql(.str, access.ty));
}

test "an array literal infers its element type and length" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = [1, 2, 3]\n    println(a[0])\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const ty = l.program.functions[0].locals[0].ty;
    try testing.expect(ty == .array);
    try testing.expectEqual(@as(u64, 3), ty.array.len);
    try testing.expect(types.Type.eql(.int, ty.array.elem.*));
}

test "indexing yields the element type" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = [\"x\"]\n    println(a[0])\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    const idx = l.program.functions[0].body.stmts[1].expr.call_builtin.args[0].index;
    try testing.expect(types.Type.eql(.str, idx.ty));
}

test "an unknown field reports E0019" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n}\nfn main() {\n    let p = P { x: 1 }\n    println(p.z)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unknown_field));
}

test "a missing field reports E0020" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n    y: Int\n}\nfn main() {\n    let p = P { x: 1 }\n    println(p.x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.missing_field));
}

test "a duplicated field in a literal reports E0011" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n}\nfn main() {\n    let p = P { x: 1, x: 2 }\n    println(p.x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.duplicate_binding));
}

test "a constant out of bounds index reports E0022" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = [1, 2]\n    println(a[5])\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.not_indexable));
}

test "a negative constant index reports E0022" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = [1, 2]\n    println(a[-1])\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.not_indexable));
}

test "indexing a non array reports E0022" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let n = 3\n    println(n[0])\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.not_indexable));
}

test "a non int index reports E0008" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = [1]\n    println(a[\"x\"])\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "mixed array element types report E0008" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = [1, \"two\"]\n    println(a[0])\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "an empty array literal cannot be inferred" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let a = []\n    println(a[0])\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.invalid_operand));
}

test "printing a struct reports a type mismatch" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n}\nfn main() {\n    let p = P { x: 1 }\n    println(p)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "nested arrays type correctly" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let g = [[1, 2], [3, 4]]\n    println(g[0][1])\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    const ty = l.program.functions[0].locals[0].ty;
    try testing.expectEqual(@as(u64, 2), ty.array.len);
    try testing.expectEqual(@as(u64, 2), ty.array.elem.array.len);
}

test "a unit variant lowers to an enum literal" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn main() {\n    let c = Red\n    println(1)\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const lit = l.program.functions[0].body.stmts[0].let.init.enum_lit;
    try testing.expectEqual(@as(u32, 0), lit.variant);
    try testing.expectEqual(@as(usize, 0), lit.payload.len);
}

test "a payload variant carries its arguments" {
    var l = try lowerText(testing.allocator, "enum S {\n    Pair(Int, Int)\n}\nfn main() {\n    let s = Pair(1, 2)\n    println(1)\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const lit = l.program.functions[0].body.stmts[0].let.init.enum_lit;
    try testing.expectEqual(@as(usize, 2), lit.payload.len);
    try testing.expectEqual(@as(i64, 2), lit.payload[1].int_const.value);
}

test "match binds payload values to local slots" {
    var l = try lowerText(testing.allocator, "enum S {\n    Pair(Int, Int)\n}\nfn f(s: S) -> Int {\n    match s {\n        Pair(a, b) => a + b\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    const m = l.program.functions[0].body.result.?.match;
    try testing.expectEqual(@as(usize, 1), m.arms.len);
    try testing.expectEqual(@as(usize, 2), m.arms[0].bindings.len);
    try testing.expect(types.Type.eql(.int, m.ty));
}

test "an exhaustive match needs no wildcard" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn f(c: C) -> Int {\n    match c {\n        Red => 1\n        Green => 2\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "a missing variant reports E0023" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn f(c: C) -> Int {\n    match c {\n        Red => 1\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.non_exhaustive));
}

test "a wildcard makes a match exhaustive" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn f(c: C) -> Int {\n    match c {\n        Red => 1\n        _ => 0\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "a repeated variant reports E0024" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn f(c: C) -> Int {\n    match c {\n        Red => 1\n        Red => 2\n        Green => 3\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unreachable_arm));
}

test "an arm after a wildcard reports E0024" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn f(c: C) -> Int {\n    match c {\n        _ => 0\n        Red => 1\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unreachable_arm));
}

test "an unknown variant in a pattern reports E0025" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n}\nfn f(c: C) -> Int {\n    match c {\n        Blue => 1\n        _ => 0\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.bad_pattern));
}

test "the wrong binding count reports E0025 without cascading" {
    var l = try lowerText(testing.allocator, "enum S {\n    Pair(Int, Int)\n}\nfn f(s: S) -> Int {\n    match s {\n        Pair(a) => a\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.bad_pattern));
    try testing.expect(!l.has(.unknown_variable));
    try testing.expectEqual(@as(usize, 1), l.diags.list.items.len);
}

test "arms of different types report E0008" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn f(c: C) -> Int {\n    match c {\n        Red => 1\n        Green => \"two\"\n    }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "matching a non enum reports E0025" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let n = 3\n    println(match n {\n        _ => 1\n    })\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.bad_pattern));
}

test "a wrong payload arity reports E0007" {
    var l = try lowerText(testing.allocator, "enum S {\n    One(Int)\n}\nfn main() {\n    let s = One(1, 2)\n    println(1)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.wrong_arg_count));
}

test "a wrong payload type reports E0008" {
    var l = try lowerText(testing.allocator, "enum S {\n    One(Int)\n}\nfn main() {\n    let s = One(\"x\")\n    println(1)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "pattern bindings do not leak out of their arm" {
    var l = try lowerText(testing.allocator, "enum S {\n    One(Int)\n}\nfn f(s: S) -> Int {\n    match s {\n        One(v) => v\n    }\n}\nfn main() {\n    println(v)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unknown_variable));
}

test "a match used as a statement is void" {
    var l = try lowerText(testing.allocator, "enum C {\n    Red\n    Green\n}\nfn main() {\n    let c = Red\n    match c {\n        Red => println(\"r\")\n        Green => println(\"g\")\n    }\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    try testing.expect(types.Type.eql(.void, l.program.functions[0].body.stmts[1].expr.match.ty));
}

test "if produces a value from both branches" {
    var l = try lowerText(testing.allocator, "fn max(a: Int, b: Int) -> Int {\n    if a > b { a } else { b }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    try testing.expect(types.Type.eql(.int, l.program.functions[0].body.result.?.if_expr.ty));
}

test "an if statement is void" {
    var l = try lowerText(testing.allocator, "fn main() {\n    if true {\n        println(\"y\")\n    }\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    try testing.expect(types.Type.eql(.void, l.program.functions[0].body.stmts[0].expr.if_expr.ty));
}

test "else if chains nest into else blocks" {
    var l = try lowerText(testing.allocator, "fn f(n: Int) -> Str {\n    if n < 0 { \"neg\" } else if n == 0 { \"zero\" } else { \"pos\" }\n}\nfn main() {\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    const outer = l.program.functions[0].body.result.?.if_expr;
    try testing.expect(outer.else_block.?.result.?.* == .if_expr);
}

test "a non bool condition reports E0008" {
    var l = try lowerText(testing.allocator, "fn main() {\n    if 1 {\n        println(\"y\")\n    }\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "mismatched branches report E0008" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x = if true { 1 } else { \"two\" }\n    println(1)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "an if value without else reports E0016 and nothing else" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x = if true { 1 }\n    println(1)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.missing_return));
    try testing.expect(!l.has(.unused_value));
}

test "while loops are void and take a bool" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let mut i = 0\n    while i < 3 {\n        i = i + 1\n    }\n    println(i)\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    try testing.expect(l.program.functions[0].body.stmts[1].expr == .while_expr);
}

test "assigning to an immutable binding reports E0027" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x = 1\n    x = 2\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.immutable_assign));
}

test "a mutable binding accepts assignment" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let mut x = 1\n    x = 2\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    try testing.expect(l.program.functions[0].locals[0].assigned);
    try testing.expect(l.program.functions[0].locals[0].is_mut);
}

test "assigning a wrong type reports E0008" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let mut x = 1\n    x = \"no\"\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "assigning to a literal reports E0026" {
    var l = try lowerText(testing.allocator, "fn main() {\n    1 = 2\n    println(1)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.not_assignable));
}

test "assigning through a field marks the root local" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n}\nfn main() {\n    let mut p = P { x: 1 }\n    p.x = 5\n    println(p.x)\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    try testing.expect(l.program.functions[0].locals[0].assigned);
}

test "assigning through an immutable field root reports E0027" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n}\nfn main() {\n    let p = P { x: 1 }\n    p.x = 5\n    println(p.x)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.immutable_assign));
}

test "block scoping keeps inner bindings local" {
    var l = try lowerText(testing.allocator, "fn main() {\n    if true {\n        let inner = 1\n        println(inner)\n    }\n    println(inner)\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unknown_variable));
}

test "shadowing is allowed across nested scopes" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x = 1\n    if true {\n        let x = 2\n        println(x)\n    }\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "bool literals and logic type check" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(true and not false)\n    println(1 == 1 or false)\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "a generic function instantiates once per type" {
    var l = try lowerText(testing.allocator, "fn id<T>(x: T) -> T {\n    x\n}\n" ++
        "fn main() {\n    println(id(1))\n    println(id(\"a\"))\n    println(id(2))\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());

    var instances: usize = 0;
    for (l.program.functions) |f| {
        if (std.mem.startsWith(u8, f.name, "id_")) instances += 1;
    }
    try testing.expectEqual(@as(usize, 2), instances);
}

test "instances carry substituted types" {
    var l = try lowerText(testing.allocator, "fn id<T>(x: T) -> T {\n    x\n}\n" ++
        "fn main() {\n    println(id(1))\n}\n");
    defer l.deinit();

    for (l.program.functions) |f| {
        if (!std.mem.eql(u8, f.name, "id_Int")) continue;
        try testing.expect(types.Type.eql(.int, f.ret));
        try testing.expect(types.Type.eql(.int, f.locals[0].ty));
        return;
    }
    return error.InstanceNotFound;
}

test "a generic function is not emitted uninstantiated" {
    var l = try lowerText(testing.allocator, "fn unused<T>(x: T) -> T {\n    x\n}\n" ++
        "fn main() {\n    println(1)\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), l.program.functions.len);
}

test "conflicting inference reports a type mismatch" {
    var l = try lowerText(testing.allocator, "fn pair<T>(a: T, b: T) -> T {\n    a\n}\n" ++
        "fn main() {\n    println(pair(1, \"two\"))\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "an uninferable parameter reports E0032" {
    var l = try lowerText(testing.allocator, "fn make<T>() -> Int {\n    1\n}\n" ++
        "fn main() {\n    println(make())\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.cannot_infer));
}

test "generics unify through references" {
    var l = try lowerText(testing.allocator, "fn deref<T>(x: &T) -> Int {\n    1\n}\n" ++
        "fn main() {\n    let n = 5\n    println(deref(&n))\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "a trait method resolves through the impl" {
    var l = try lowerText(testing.allocator, "trait Show {\n    fn show(self) -> Str\n}\n" ++
        "struct U {\n    n: Str\n}\n" ++
        "impl Show for U {\n    fn show(self) -> Str {\n        self.n\n    }\n}\n" ++
        "fn main() {\n    let u = U { n: \"a\" }\n    println(u.show())\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "an unknown method reports E0034" {
    var l = try lowerText(testing.allocator, "struct P {\n    x: Int\n}\n" ++
        "fn main() {\n    let p = P { x: 1 }\n    println(p.nope())\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unknown_method));
}

test "an unsatisfied bound reports E0035" {
    var l = try lowerText(testing.allocator, "trait Show {\n    fn show(self) -> Str\n}\n" ++
        "struct A {\n    v: Int\n}\n" ++
        "struct B {\n    v: Int\n}\n" ++
        "impl Show for A {\n    fn show(self) -> Str {\n        \"a\"\n    }\n}\n" ++
        "fn go<T: Show>(x: T) -> Str {\n    x.show()\n}\n" ++
        "fn main() {\n    let b = B { v: 1 }\n    println(go(b))\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.missing_impl));
}

test "a satisfied bound lowers cleanly" {
    var l = try lowerText(testing.allocator, "trait Show {\n    fn show(self) -> Str\n}\n" ++
        "struct A {\n    v: Int\n}\n" ++
        "impl Show for A {\n    fn show(self) -> Str {\n        \"a\"\n    }\n}\n" ++
        "fn go<T: Show>(x: T) -> Str {\n    x.show()\n}\n" ++
        "fn main() {\n    let a = A { v: 1 }\n    println(go(a))\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "the question mark unwraps and propagates" {
    var l = try lowerText(testing.allocator, "enum Result<T, E> {\n    Ok(T)\n    Err(E)\n}\n" ++
        "fn a() -> Result<Int, Str> {\n    Ok(1)\n}\n" ++
        "fn b() -> Result<Int, Str> {\n    let v = a()?\n    Ok(v + 1)\n}\n" ++
        "fn main() {\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "the question mark rejects mismatched error types" {
    var l = try lowerText(testing.allocator, "enum Result<T, E> {\n    Ok(T)\n    Err(E)\n}\n" ++
        "fn a() -> Result<Int, Str> {\n    Ok(1)\n}\n" ++
        "fn b() -> Result<Int, Int> {\n    let v = a()?\n    Ok(v)\n}\n" ++
        "fn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.type_mismatch));
}

test "an early return type checks" {
    var l = try lowerText(testing.allocator, "fn f(n: Int) -> Int {\n    if n < 0 {\n        return 0\n    }\n    n\n}\n" ++
        "fn main() {\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "a wrongly typed return reports E0016" {
    var l = try lowerText(testing.allocator, "fn f() -> Int {\n    return \"no\"\n}\n" ++
        "fn main() {\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.missing_return));
}

test "assigning to an unknown variable reports E0012" {
    var l = try lowerText(testing.allocator, "fn main() {\n    y = 1\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unknown_variable));
}

test "mutably borrowing an unknown variable reports E0012" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let r = &mut y\n}\n");
    defer l.deinit();
    try testing.expect(l.has(.unknown_variable));
}

test "a trailing return satisfies the return type" {
    var l = try lowerText(testing.allocator, "fn f() -> Int {\n    return 1\n}\nfn main() {\n    println(f())\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "a return after an early return needs no trailing value" {
    var l = try lowerText(testing.allocator,
        \\fn f(n: Int) -> Int {
        \\    if n > 0 {
        \\        return 1
        \\    }
        \\    return 2
        \\}
        \\fn main() {
        \\    println(f(1))
        \\}
        \\
    );
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "an if whose branches both return needs no trailing value" {
    var l = try lowerText(testing.allocator,
        \\fn f(n: Int) -> Int {
        \\    if n > 0 {
        \\        return 1
        \\    } else {
        \\        return 2
        \\    }
        \\}
        \\fn main() {
        \\    println(f(1))
        \\}
        \\
    );
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "an if that only sometimes returns still needs a value" {
    var l = try lowerText(testing.allocator,
        \\fn f(n: Int) -> Int {
        \\    if n > 0 {
        \\        return 1
        \\    }
        \\}
        \\fn main() {
        \\    println(f(1))
        \\}
        \\
    );
    defer l.deinit();
    try testing.expect(l.has(.missing_return));
}

test "a returning branch unifies with a valued branch" {
    var l = try lowerText(testing.allocator,
        \\fn f(n: Int) -> Int {
        \\    if n > 0 {
        \\        return 1
        \\    } else {
        \\        2
        \\    }
        \\}
        \\fn main() {
        \\    println(f(1))
        \\}
        \\
    );
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "pushing through a shared reference reports E0027" {
    var l = try lowerText(testing.allocator,
        \\fn add(v: &Vec<Int>) {
        \\    v.push(1)
        \\}
        \\fn main(alloc: Allocator) {
        \\    let v: Vec<Int> = Vec.new(alloc)
        \\    add(&v)
        \\}
        \\
    );
    defer l.deinit();
    try testing.expect(l.has(.immutable_assign));
}

test "pushing through a mutable reference is allowed" {
    var l = try lowerText(testing.allocator,
        \\fn add(v: &mut Vec<Int>) {
        \\    v.push(1)
        \\}
        \\fn main(alloc: Allocator) {
        \\    let mut v: Vec<Int> = Vec.new(alloc)
        \\    add(&mut v)
        \\}
        \\
    );
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "appending to a string field through a shared reference reports E0027" {
    var l = try lowerText(testing.allocator,
        \\struct Log {
        \\    text: String
        \\}
        \\fn note(l: &Log) {
        \\    l.text.push("x")
        \\}
        \\fn main(alloc: Allocator) {
        \\    let log = Log { text: String.new(alloc) }
        \\    note(&log)
        \\}
        \\
    );
    defer l.deinit();
    try testing.expect(l.has(.immutable_assign));
}

test "reading through a shared reference is allowed" {
    var l = try lowerText(testing.allocator,
        \\fn count(v: &Vec<Int>) -> Int {
        \\    v.len() + v.get(0)
        \\}
        \\fn main(alloc: Allocator) {
        \\    let v: Vec<Int> = Vec.new(alloc)
        \\    v.push(1)
        \\    println(count(&v))
        \\}
        \\
    );
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
}

test "the question mark works with a plain enum" {
    var l = try lowerText(testing.allocator,
        \\enum R {
        \\    Ok(Int)
        \\    Err(Str)
        \\}
        \\fn half(n: Int) -> R {
        \\    if n % 2 == 0 { Ok(n / 2) } else { Err("odd") }
        \\}
        \\fn quarter(n: Int) -> R {
        \\    let h = half(n)?
        \\    half(h)
        \\}
        \\fn main() {
        \\    match quarter(8) {
        \\        Ok(v) => println(v)
        \\        Err(e) => println(e)
        \\    }
        \\}
        \\
    );
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    const try_expr = l.program.functions[1].body.stmts[0].let.init.try_unwrap;
    try testing.expectEqual(try_expr.source_enum, try_expr.ret_enum);
}

test "a match through a reference binds owning payloads by reference" {
    var l = try lowerText(testing.allocator,
        \\enum Holder {
        \\    Some(Vec<Int>, Int)
        \\    None
        \\}
        \\fn count(h: &Holder) -> Int {
        \\    match h {
        \\        Some(v, n) => v.len() + n
        \\        None => 0
        \\    }
        \\}
        \\fn main() {
        \\}
        \\
    );
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());

    const f = l.program.functions[0];
    const m = f.body.result.?.match;
    try testing.expect(m.by_ref);
    const v = f.locals[m.arms[0].bindings[0]];
    const n = f.locals[m.arms[0].bindings[1]];
    try testing.expect(v.ty == .ref and v.ty.ref.target.* == .vec);
    try testing.expectEqual(types.Type.int, n.ty);
}

test "an error in a generic body is reported once across instantiations" {
    var l = try lowerText(testing.allocator,
        \\fn id<T>(x: T) -> T {
        \\    y
        \\}
        \\fn main() {
        \\    let a = id(1)
        \\    let b = id("s")
        \\}
        \\
    );
    defer l.deinit();
    try testing.expectEqual(@as(usize, 1), l.diags.list.items.len);
    try testing.expect(l.has(.unknown_variable));
}

test "the most negative integer literal is accepted" {
    var l = try lowerText(testing.allocator, "fn main() {\n    let x = -9223372036854775808\n    println(x)\n}\n");
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    const init_expr = l.program.functions[0].body.stmts[0].let.init;
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), init_expr.int_const.value);
}

test "instantiating a generic while lowering main keeps main" {
    var l = try lowerText(testing.allocator,
        \\fn id<T>(x: T) -> T {
        \\    x
        \\}
        \\fn main() {
        \\    println(id(1))
        \\    println(id("s"))
        \\    println(id(true))
        \\}
        \\
    );
    defer l.deinit();
    try testing.expect(!l.diags.hasErrors());
    try testing.expectEqualStrings("main", l.program.functions[0].name);
    try testing.expect(l.program.functions[0].is_entry);
}
