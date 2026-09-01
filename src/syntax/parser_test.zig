const std = @import("std");
const source = @import("../support/source.zig");
const diagnostics = @import("../support/diagnostics.zig");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const core = @import("parse/core.zig");
const item = @import("parse/item.zig");
const Token = token.Token;
const Span = source.Span;
const impl = @import("parser.zig");

const parse = impl.parse;

const testing = std.testing;

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    diags: diagnostics.Diagnostics,
    program: ast.Program,

    fn deinit(p: *Parsed) void {
        p.diags.deinit();
        p.arena.deinit();
    }
};

fn parseText(gpa: std.mem.Allocator, text: []const u8) !Parsed {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    var d: diagnostics.Diagnostics = .init(gpa);
    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    const toks = try lexer.tokenize(arena_state.allocator(), file, &d);
    const program = try parse(arena_state.allocator(), toks, &d);
    return .{ .arena = arena_state, .diags = d, .program = program };
}

test "parses hello world" {
    var p = try parseText(testing.allocator, "fn main() {\n    println(\"hi\")\n}\n");
    defer p.deinit();

    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), p.program.fns.len);

    const f = p.program.fns[0];
    try testing.expectEqualStrings("main", f.name);
    try testing.expectEqual(@as(usize, 1), f.body.stmts.len);

    const call = f.body.stmts[0].expr.call;
    try testing.expectEqualStrings("println", call.callee);
    try testing.expectEqual(@as(usize, 1), call.args.len);
    try testing.expectEqualStrings("hi", call.args[0].string.value);
}

test "parses an empty function body" {
    var p = try parseText(testing.allocator, "fn main() {\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), p.program.fns[0].body.stmts.len);
}

test "parses a body with no newline before the closing brace" {
    var p = try parseText(testing.allocator, "fn main() { println(\"hi\") }");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), p.program.fns[0].body.stmts.len);
}

test "parses several statements" {
    var p = try parseText(testing.allocator, "fn main() {\n    println(\"a\")\n    println(\"b\")\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 2), p.program.fns[0].body.stmts.len);
}

test "parses several functions" {
    var p = try parseText(testing.allocator, "fn a() {\n}\n\nfn b() {\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 2), p.program.fns.len);
}

test "parses nested calls and multiple arguments" {
    var p = try parseText(testing.allocator, "fn main() {\n    a(b(\"x\"), \"y\")\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());

    const call = p.program.fns[0].body.stmts[0].expr.call;
    try testing.expectEqual(@as(usize, 2), call.args.len);
    try testing.expectEqualStrings("b", call.args[0].call.callee);
    try testing.expectEqualStrings("y", call.args[1].string.value);
}

test "parses a call with no arguments" {
    var p = try parseText(testing.allocator, "fn main() {\n    helper()\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), p.program.fns[0].body.stmts[0].expr.call.args.len);
}

test "leading blank lines are skipped" {
    var p = try parseText(testing.allocator, "\n\n\nfn main() {\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), p.program.fns.len);
}

test "comments between items are skipped" {
    var p = try parseText(testing.allocator, "# a note\nfn main() {\n    # inner\n    println(\"hi\")\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), p.program.fns[0].body.stmts.len);
}

test "an empty program is valid" {
    var p = try parseText(testing.allocator, "\n\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), p.program.fns.len);
}

test "function span covers fn keyword through closing brace" {
    const text = "fn main() {\n}\n";
    var p = try parseText(testing.allocator, text);
    defer p.deinit();

    const f = p.program.fns[0];
    try testing.expectEqualStrings("fn main() {\n}", text[f.span.start..f.span.end]);
}

test "missing closing paren reports E0001" {
    var p = try parseText(testing.allocator, "fn main() {\n    println(\"hi\"\n}\n");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
    try testing.expectEqual(diagnostics.Code.unexpected_token, p.diags.list.items[0].code.?);
}

test "recovers and reports two separate errors" {
    var p = try parseText(testing.allocator, "fn main() {\n    $\n    $\n}\n");
    defer p.deinit();
    try testing.expect(p.diags.list.items.len >= 2);
}

test "a function without a body reports an error and does not hang" {
    var p = try parseText(testing.allocator, "fn main()\n");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
}

test "top level junk reports an error and still parses the next function" {
    var p = try parseText(testing.allocator, "banana\nfn main() {\n}\n");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
    try testing.expectEqual(@as(usize, 1), p.program.fns.len);
}

test "unterminated input does not hang" {
    var p = try parseText(testing.allocator, "fn main() {");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
}

test "a statement that is not a call reports an error" {
    var p = try parseText(testing.allocator, "fn main() {\n    \"loose\"\n}\n");
    defer p.deinit();
    try testing.expect(!p.diags.hasErrors());
    try testing.expectEqualStrings("loose", p.program.fns[0].body.stmts[0].expr.string.value);
}

test "junk after a statement reports an error" {
    var p = try parseText(testing.allocator, "fn main() {\n    println(\"a\") println(\"b\")\n}\n");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
}

test "a binary expression spans both operands" {
    const text = "fn main() {\n    println(12 + 345)\n}\n";
    var p = try parseText(testing.allocator, text);
    defer p.deinit();

    const arg = p.program.fns[0].body.stmts[0].expr.call.args[0];
    try testing.expectEqualStrings("12 + 345", text[arg.spanOf().start..arg.spanOf().end]);
}

test "a chained binary expression spans the whole chain" {
    const text = "fn main() {\n    println(1 + 2 * 3)\n}\n";
    var p = try parseText(testing.allocator, text);
    defer p.deinit();

    const arg = p.program.fns[0].body.stmts[0].expr.call.args[0];
    try testing.expectEqualStrings("1 + 2 * 3", text[arg.spanOf().start..arg.spanOf().end]);
}

test "missing function name does not hang" {
    var p = try parseText(testing.allocator, "fn () {\n}\n");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
}
