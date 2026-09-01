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

const Error = error{OutOfMemory};

pub fn run(
    arena: std.mem.Allocator,
    program: ast.Program,
    symbols: *const resolve.SymbolTable,
) Error!tir.Program {
    var functions: std.ArrayList(tir.Function) = .empty;

    for (program.fns, 0..) |f, index| {
        var stmts: std.ArrayList(tir.Stmt) = .empty;
        for (f.body.stmts) |stmt| {
            try stmts.append(arena, .{ .expr = try lowerExpr(arena, stmt.expr, symbols) });
        }

        try functions.append(arena, .{
            .name = f.name,
            .is_entry = symbols.entry != null and symbols.entry.? == index,
            .body = .{ .stmts = try stmts.toOwnedSlice(arena) },
            .span = f.span,
        });
    }

    return .{ .functions = try functions.toOwnedSlice(arena) };
}

fn lowerExpr(
    arena: std.mem.Allocator,
    expr: ast.Expr,
    symbols: *const resolve.SymbolTable,
) Error!tir.Expr {
    switch (expr) {
        .string => |s| return .{ .string_const = .{
            .value = s.value,
            .ty = .str,
            .span = s.span,
        } },
        .call => |c| {
            var args: std.ArrayList(tir.Expr) = .empty;
            for (c.args) |arg| try args.append(arena, try lowerExpr(arena, arg, symbols));
            const lowered_args = try args.toOwnedSlice(arena);

            const symbol = symbols.lookup(c.callee).?;
            return switch (symbol) {
                .builtin => |b| .{ .call_builtin = .{
                    .builtin = builtinOf(b),
                    .args = lowered_args,
                    .ty = b.resultType(),
                    .span = c.span,
                } },
                .function => |target| .{ .call_function = .{
                    .target = target,
                    .args = lowered_args,
                    .ty = .void,
                    .span = c.span,
                } },
            };
        },
    }
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
};

fn lowerText(gpa: std.mem.Allocator, text: []const u8) !Lowered {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    var d: diagnostics.Diagnostics = .init(gpa);
    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    const toks = try lexer.tokenize(arena_state.allocator(), file, &d);
    const parsed = try parser.parse(arena_state.allocator(), toks, &d);
    var symbols = try resolve.run(gpa, parsed, &d);
    try typecheck.run(parsed, &symbols, &d);
    const program = try run(arena_state.allocator(), parsed, &symbols);
    return .{ .arena = arena_state, .diags = d, .symbols = symbols, .program = program };
}

test "lowers println to the print_line builtin" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(\"hi\")\n}\n");
    defer l.deinit();

    try testing.expect(!l.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), l.program.functions.len);

    const f = l.program.functions[0];
    try testing.expectEqualStrings("main", f.name);
    try testing.expect(f.is_entry);

    const call = f.body.stmts[0].expr.call_builtin;
    try testing.expectEqual(tir.Builtin.print_line, call.builtin);
    try testing.expectEqual(types.Type.void, call.ty);
    try testing.expectEqual(@as(usize, 1), call.args.len);

    const arg = call.args[0].string_const;
    try testing.expectEqualStrings("hi", arg.value);
    try testing.expectEqual(types.Type.str, arg.ty);
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

    const call = l.program.functions[1].body.stmts[0].expr.call_function;
    try testing.expectEqual(@as(usize, 0), call.target);
    try testing.expectEqual(types.Type.void, call.ty);
}

test "lowers nested calls" {
    var l = try lowerText(testing.allocator, "fn main() {\n    println(\"a\")\n    println(\"b\")\n}\n");
    defer l.deinit();

    const stmts = l.program.functions[0].body.stmts;
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expectEqualStrings("a", stmts[0].expr.call_builtin.args[0].string_const.value);
    try testing.expectEqualStrings("b", stmts[1].expr.call_builtin.args[0].string_const.value);
}

test "function order is preserved so call targets stay valid" {
    var l = try lowerText(testing.allocator, "fn a() {\n}\nfn b() {\n}\nfn main() {\n    a()\n    b()\n}\n");
    defer l.deinit();

    try testing.expectEqualStrings("a", l.program.functions[0].name);
    try testing.expectEqualStrings("b", l.program.functions[1].name);

    const stmts = l.program.functions[2].body.stmts;
    try testing.expectEqualStrings("a", l.program.functions[stmts[0].expr.call_function.target].name);
    try testing.expectEqualStrings("b", l.program.functions[stmts[1].expr.call_function.target].name);
}

test "spans survive lowering" {
    const text = "fn main() {\n    println(\"hi\")\n}\n";
    var l = try lowerText(testing.allocator, text);
    defer l.deinit();

    const arg = l.program.functions[0].body.stmts[0].expr.call_builtin.args[0].string_const;
    try testing.expectEqualStrings("\"hi\"", text[arg.span.start..arg.span.end]);
}

test "an empty program lowers to no functions" {
    var l = try lowerText(testing.allocator, "\n");
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.program.functions.len);
}
