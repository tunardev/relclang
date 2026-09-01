const std = @import("std");
const source = @import("source.zig");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const ast = @import("ast.zig");
const types = @import("types.zig");

const Error = error{OutOfMemory};

pub fn run(
    program: ast.Program,
    symbols: *const resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
) Error!void {
    for (program.fns) |f| {
        for (f.body.stmts) |stmt| _ = try typeOf(stmt.expr, symbols, diags);
    }
}

pub fn typeOf(
    expr: ast.Expr,
    symbols: *const resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
) Error!types.Type {
    return switch (expr) {
        .string => .str,
        .call => |c| try typeOfCall(c, symbols, diags),
    };
}

fn typeOfCall(
    c: ast.Call,
    symbols: *const resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
) Error!types.Type {
    const symbol = symbols.lookup(c.callee) orelse return .invalid;

    switch (symbol) {
        .builtin => |b| {
            const want = b.arity();
            if (c.args.len != want) {
                try diags.err(
                    .wrong_arg_count,
                    c.span,
                    "wrong number of arguments",
                    if (c.args.len > want) "too many arguments" else "too few arguments",
                    null,
                );
                for (c.args) |arg| _ = try typeOf(arg, symbols, diags);
                return b.resultType();
            }

            for (c.args, 0..) |arg, i| {
                const got = try typeOf(arg, symbols, diags);
                const expected = b.paramType(i);
                if (got != expected and got != .invalid) {
                    try diags.err(
                        .type_mismatch,
                        arg.spanOf(),
                        "argument type mismatch",
                        expected.name(),
                        null,
                    );
                }
            }
            return b.resultType();
        },
        .function => {
            if (c.args.len != 0) {
                try diags.err(
                    .wrong_arg_count,
                    c.span,
                    "wrong number of arguments",
                    "functions take no parameters yet",
                    null,
                );
            }
            for (c.args) |arg| _ = try typeOf(arg, symbols, diags);
            return .void;
        },
    }
}

const testing = std.testing;

fn checkText(gpa: std.mem.Allocator, text: []const u8) !diagnostics.Diagnostics {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var d: diagnostics.Diagnostics = .init(gpa);
    errdefer d.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    const toks = try lexer.tokenize(arena_state.allocator(), file, &d);
    const program = try parser.parse(arena_state.allocator(), toks, &d);
    var symbols = try resolve.run(gpa, program, &d);
    defer symbols.deinit();
    try run(program, &symbols, &d);
    return d;
}

fn hasCode(d: diagnostics.Diagnostics, code: diagnostics.Code) bool {
    for (d.list.items) |item| {
        if (item.code == code) return true;
    }
    return false;
}

test "hello world type checks" {
    var d = try checkText(testing.allocator, "fn main() {\n    println(\"hi\")\n}\n");
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}

test "too many arguments reports E0007" {
    var d = try checkText(testing.allocator, "fn main() {\n    println(\"a\", \"b\")\n}\n");
    defer d.deinit();
    try testing.expect(hasCode(d, .wrong_arg_count));
}

test "too few arguments reports E0007" {
    var d = try checkText(testing.allocator, "fn main() {\n    println()\n}\n");
    defer d.deinit();
    try testing.expect(hasCode(d, .wrong_arg_count));
}

test "wrong argument type reports E0008" {
    var d = try checkText(testing.allocator, "fn helper() {\n}\nfn main() {\n    println(helper())\n}\n");
    defer d.deinit();
    try testing.expect(hasCode(d, .type_mismatch));
}

test "calling a user function with arguments reports E0007" {
    var d = try checkText(testing.allocator, "fn helper() {\n}\nfn main() {\n    helper(\"x\")\n}\n");
    defer d.deinit();
    try testing.expect(hasCode(d, .wrong_arg_count));
}

test "an unknown callee does not cascade a type error" {
    var d = try checkText(testing.allocator, "fn main() {\n    println(nope())\n}\n");
    defer d.deinit();
    try testing.expect(hasCode(d, .unknown_function));
    try testing.expect(!hasCode(d, .type_mismatch));
}

test "a user function call type checks as void" {
    var d = try checkText(testing.allocator, "fn helper() {\n}\nfn main() {\n    helper()\n}\n");
    defer d.deinit();
    try testing.expect(!d.hasErrors());
}
