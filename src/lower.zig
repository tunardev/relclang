const std = @import("std");
const source = @import("source.zig");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const typecheck = @import("typecheck.zig");
const ast = @import("ast.zig");
const tir = @import("tir.zig");
const types = @import("types.zig");

const Span = source.Span;
const Type = types.Type;

const Error = error{OutOfMemory};

const Binding = struct {
    name: []const u8,
    slot: u32,
    ty: Type,
    depth: u32,
};

const Fn = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    symbols: *const resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
    bindings: std.ArrayList(Binding),
    locals: std.ArrayList(tir.Local),
    depth: u32,

    fn deinit(f: *Fn) void {
        f.bindings.deinit(f.gpa);
    }

    fn lookup(f: *Fn, name: []const u8) ?Binding {
        var i = f.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, f.bindings.items[i].name, name)) return f.bindings.items[i];
        }
        return null;
    }

    fn declaredAtDepth(f: *Fn, name: []const u8) bool {
        for (f.bindings.items) |b| {
            if (b.depth == f.depth and std.mem.eql(u8, b.name, name)) return true;
        }
        return false;
    }

    fn declare(f: *Fn, name: []const u8, ty: Type) Error!u32 {
        const slot: u32 = @intCast(f.locals.items.len);
        try f.locals.append(f.arena, .{ .name = name, .ty = ty, .used = false });
        try f.bindings.append(f.gpa, .{ .name = name, .slot = slot, .ty = ty, .depth = f.depth });
        return slot;
    }

    fn box(f: *Fn, e: tir.Expr) Error!*const tir.Expr {
        const ptr = try f.arena.create(tir.Expr);
        ptr.* = e;
        return ptr;
    }
};

pub fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    program: ast.Program,
    symbols: *const resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
) Error!tir.Program {
    var functions: std.ArrayList(tir.Function) = .empty;

    for (program.fns, 0..) |f, index| {
        var ctx: Fn = .{
            .arena = arena,
            .gpa = gpa,
            .symbols = symbols,
            .diags = diags,
            .bindings = .empty,
            .locals = .empty,
            .depth = 0,
        };
        defer ctx.deinit();

        const info = symbols.signature(index);

        for (f.params, 0..) |param, i| {
            if (ctx.declaredAtDepth(param.name)) {
                try diags.err(
                    .duplicate_binding,
                    param.name_span,
                    try diags.fmt("`{s}` is already a parameter", .{param.name}),
                    "duplicate parameter",
                    null,
                );
            }
            _ = try ctx.declare(param.name, info.params[i]);
            ctx.locals.items[i].used = true;
        }

        const param_count: u32 = @intCast(f.params.len);

        var stmts: std.ArrayList(tir.Stmt) = .empty;
        const last = f.body.stmts.len;

        for (f.body.stmts, 0..) |stmt, i| {
            const is_last = i + 1 == last;
            const lowered = try lowerStmt(&ctx, stmt) orelse continue;

            if (is_last and info.ret != .void and lowered == .expr) {
                const ty = lowered.expr.typeOf();
                if (ty != .invalid and ty != info.ret) {
                    try diags.err(
                        .missing_return,
                        lowered.expr.spanOf(),
                        "the final expression does not match the return type",
                        try diags.fmt("expected `{s}`, found `{s}`", .{ info.ret.name(), ty.name() }),
                        null,
                    );
                }
                try stmts.append(arena, .{ .ret_value = lowered.expr });
                continue;
            }

            if (lowered == .expr) {
                const ty = lowered.expr.typeOf();
                if (ty != .void and ty != .invalid) {
                    try diags.err(
                        .unused_value,
                        lowered.expr.spanOf(),
                        try diags.fmt("this `{s}` value is not used", .{ty.name()}),
                        "the value is discarded",
                        "bind it with `let`, or remove it",
                    );
                }
            }

            try stmts.append(arena, lowered);
        }

        if (info.ret != .void) {
            const returns = last > 0 and stmts.items.len > 0 and stmts.items[stmts.items.len - 1] == .ret_value;
            if (!returns) {
                try diags.err(
                    .missing_return,
                    f.ret_ty_span orelse f.name_span,
                    try diags.fmt("`{s}` must end with a `{s}` value", .{ f.name, info.ret.name() }),
                    "no value is returned",
                    "the last line of the body is its return value",
                );
            }
        }

        try functions.append(arena, .{
            .name = f.name,
            .is_entry = symbols.entry != null and symbols.entry.? == index,
            .param_count = param_count,
            .ret = info.ret,
            .locals = try ctx.locals.toOwnedSlice(arena),
            .body = .{ .stmts = try stmts.toOwnedSlice(arena) },
            .span = f.span,
        });
    }

    return .{ .functions = try functions.toOwnedSlice(arena) };
}

fn lowerStmt(f: *Fn, stmt: ast.Stmt) Error!?tir.Stmt {
    switch (stmt) {
        .expr => |e| return .{ .expr = try lowerExpr(f, e) },
        .let => |l| {
            const init_expr = try lowerExpr(f, l.init);
            var ty = init_expr.typeOf();

            if (l.ty_name) |name| {
                const annotated = typecheck.typeFromName(name) orelse blk: {
                    try f.diags.err(
                        .type_mismatch,
                        l.ty_span.?,
                        try f.diags.fmt("unknown type `{s}`", .{name}),
                        "not a known type",
                        "the types are `Int`, `Str` and `Void`",
                    );
                    break :blk Type.invalid;
                };

                if (annotated != .invalid and ty != .invalid and annotated != ty) {
                    try f.diags.err(
                        .type_mismatch,
                        l.init.spanOf(),
                        "type does not match the annotation",
                        try f.diags.fmt("expected `{s}`, found `{s}`", .{ annotated.name(), ty.name() }),
                        null,
                    );
                }
                ty = annotated;
            }

            if (ty == .void) {
                try f.diags.err(
                    .invalid_operand,
                    l.init.spanOf(),
                    "cannot bind a value of type `Void`",
                    "this expression produces no value",
                    null,
                );
                ty = .invalid;
            }

            if (f.declaredAtDepth(l.name)) {
                try f.diags.err(
                    .duplicate_binding,
                    l.name_span,
                    try f.diags.fmt("`{s}` is already defined in this scope", .{l.name}),
                    "duplicate binding",
                    "shadowing is not allowed yet, pick another name",
                );
            }

            const slot = try f.declare(l.name, ty);

            return .{ .let = .{
                .slot = slot,
                .init = init_expr,
                .ty = ty,
                .span = l.span,
            } };
        },
    }
}

fn lowerExpr(f: *Fn, expr: ast.Expr) Error!tir.Expr {
    switch (expr) {
        .string => |s| return .{ .string_const = .{ .value = s.value, .ty = .str, .span = s.span } },

        .int => |i| {
            const value = parseInt(i.text) catch {
                try f.diags.err(
                    .integer_overflow,
                    i.span,
                    "integer literal is out of range",
                    "does not fit in `Int`",
                    "`Int` holds values from -9223372036854775808 to 9223372036854775807",
                );
                return .{ .int_const = .{ .value = 0, .ty = .invalid, .span = i.span } };
            };
            return .{ .int_const = .{ .value = value, .ty = .int, .span = i.span } };
        },

        .var_ref => |v| {
            const binding = f.lookup(v.name) orelse {
                try f.diags.err(
                    .unknown_variable,
                    v.span,
                    try f.diags.fmt("cannot find `{s}` in this scope", .{v.name}),
                    "not defined here",
                    null,
                );
                return .{ .local_ref = .{ .slot = 0, .ty = .invalid, .span = v.span } };
            };
            f.locals.items[binding.slot].used = true;
            return .{ .local_ref = .{ .slot = binding.slot, .ty = binding.ty, .span = v.span } };
        },

        .unary => |u| {
            const operand = try lowerExpr(f, u.operand.*);
            const ty = typecheck.unaryResult(u.op, operand.typeOf()) orelse blk: {
                try f.diags.err(
                    .invalid_operand,
                    u.span,
                    try f.diags.fmt("`{s}` cannot be applied to `{s}`", .{
                        u.op.symbol(),
                        operand.typeOf().name(),
                    }),
                    "invalid operand",
                    null,
                );
                break :blk Type.invalid;
            };
            return .{ .unary = .{
                .op = unOpOf(u.op),
                .operand = try f.box(operand),
                .ty = ty,
                .span = u.span,
            } };
        },

        .binary => |b| {
            const lhs = try lowerExpr(f, b.lhs.*);
            const rhs = try lowerExpr(f, b.rhs.*);
            const ty = typecheck.binaryResult(b.op, lhs.typeOf(), rhs.typeOf()) orelse blk: {
                try f.diags.err(
                    .invalid_operand,
                    b.op_span,
                    try f.diags.fmt("`{s}` cannot be applied to `{s}` and `{s}`", .{
                        b.op.symbol(),
                        lhs.typeOf().name(),
                        rhs.typeOf().name(),
                    }),
                    "invalid operands",
                    if (lhs.typeOf() == .str and rhs.typeOf() == .str)
                        "string concatenation is not supported yet"
                    else
                        null,
                );
                break :blk Type.invalid;
            };
            return .{ .binary = .{
                .op = binOpOf(b.op),
                .lhs = try f.box(lhs),
                .rhs = try f.box(rhs),
                .ty = ty,
                .span = b.span,
            } };
        },

        .call => |c| return lowerCall(f, c),
    }
}

fn lowerCall(f: *Fn, c: ast.Call) Error!tir.Expr {
    var args: std.ArrayList(tir.Expr) = .empty;
    for (c.args) |arg| try args.append(f.arena, try lowerExpr(f, arg));
    const lowered = try args.toOwnedSlice(f.arena);

    const symbol = f.symbols.lookup(c.callee) orelse {
        try f.diags.err(
            .unknown_function,
            c.callee_span,
            try f.diags.fmt("unknown function `{s}`", .{c.callee}),
            "not defined anywhere",
            null,
        );
        return .{ .call_builtin = .{
            .builtin = .print_line,
            .args = lowered,
            .ty = .invalid,
            .span = c.span,
        } };
    };

    switch (symbol) {
        .builtin => |b| {
            const want = b.arity();
            if (lowered.len != want) {
                try f.diags.err(
                    .wrong_arg_count,
                    c.span,
                    try f.diags.fmt("`{s}` takes {d} {s}", .{
                        c.callee,
                        want,
                        if (want == 1) "argument" else "arguments",
                    }),
                    try f.diags.fmt("expected {d}, found {d}", .{ want, lowered.len }),
                    null,
                );
            } else {
                for (lowered, 0..) |arg, i| {
                    const ty = arg.typeOf();
                    if (ty != .invalid and !b.accepts(i, ty)) {
                        try f.diags.err(
                            .type_mismatch,
                            arg.spanOf(),
                            "argument type mismatch",
                            try f.diags.fmt("expected {s}, found `{s}`", .{ b.describeParam(i), ty.name() }),
                            null,
                        );
                    }
                }
            }
            return .{ .call_builtin = .{
                .builtin = builtinOf(b),
                .args = lowered,
                .ty = b.resultType(),
                .span = c.span,
            } };
        },
        .function => |target| {
            const info = f.symbols.signature(target);
            if (lowered.len != info.params.len) {
                try f.diags.err(
                    .wrong_arg_count,
                    c.span,
                    try f.diags.fmt("`{s}` takes {d} {s}", .{
                        c.callee,
                        info.params.len,
                        if (info.params.len == 1) "argument" else "arguments",
                    }),
                    try f.diags.fmt("expected {d}, found {d}", .{ info.params.len, lowered.len }),
                    null,
                );
            } else {
                for (lowered, 0..) |arg, i| {
                    const ty = arg.typeOf();
                    if (ty != .invalid and ty != info.params[i]) {
                        try f.diags.err(
                            .type_mismatch,
                            arg.spanOf(),
                            "argument type mismatch",
                            try f.diags.fmt("expected `{s}`, found `{s}`", .{ info.params[i].name(), ty.name() }),
                            null,
                        );
                    }
                }
            }
            return .{ .call_function = .{
                .target = target,
                .args = lowered,
                .ty = info.ret,
                .span = c.span,
            } };
        },
    }
}

fn parseInt(text: []const u8) !i64 {
    var value: i64 = 0;
    for (text) |ch| {
        if (ch == '_') continue;
        const digit: i64 = ch - '0';
        value = try std.math.add(i64, try std.math.mul(i64, value, 10), digit);
    }
    return value;
}

fn binOpOf(op: ast.BinOp) tir.BinOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .rem => .rem,
    };
}

fn unOpOf(op: ast.UnOp) tir.UnOp {
    return switch (op) {
        .neg => .neg,
    };
}

fn builtinOf(b: resolve.Builtin) tir.Builtin {
    return switch (b) {
        .println => .print_line,
    };
}

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

    const stmts = l.program.functions[0].body.stmts;
    try testing.expectEqual(@as(i64, 7), stmts[stmts.len - 1].ret_value.int_const.value);
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
