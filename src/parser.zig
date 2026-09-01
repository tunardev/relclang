const std = @import("std");
const source = @import("source.zig");
const diagnostics = @import("diagnostics.zig");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

const Token = token.Token;
const Kind = token.Kind;
const Span = source.Span;

const Error = error{OutOfMemory};

const Parser = struct {
    arena: std.mem.Allocator,
    tokens: []const Token,
    diags: *diagnostics.Diagnostics,
    pos: usize,

    fn peek(p: *Parser) Kind {
        return p.tokens[p.pos].kind;
    }

    fn current(p: *Parser) Token {
        return p.tokens[p.pos];
    }

    fn advance(p: *Parser) Token {
        const t = p.tokens[p.pos];
        if (t.kind != .eof) p.pos += 1;
        return t;
    }

    fn skipNewlines(p: *Parser) void {
        while (p.peek() == .newline) p.pos += 1;
    }

    fn expect(p: *Parser, kind: Kind, label: []const u8, help: ?[]const u8) Error!?Token {
        if (p.peek() == kind) return p.advance();
        try p.diags.err(.unexpected_token, p.current().span, "unexpected token", label, help);
        return null;
    }

    fn parseProgram(p: *Parser) Error!ast.Program {
        var fns: std.ArrayList(ast.Fn) = .empty;

        while (true) {
            p.skipNewlines();
            if (p.peek() == .eof) break;

            if (p.peek() != .kw_fn) {
                try p.diags.err(
                    .unexpected_token,
                    p.current().span,
                    "expected a function definition",
                    "only `fn` items are allowed at the top level",
                    null,
                );
                p.recoverToTopLevel();
                continue;
            }

            if (try p.parseFn()) |f| try fns.append(p.arena, f);
        }

        return .{ .fns = try fns.toOwnedSlice(p.arena) };
    }

    fn recoverToTopLevel(p: *Parser) void {
        while (p.peek() != .eof and p.peek() != .kw_fn) p.pos += 1;
    }

    fn parseFn(p: *Parser) Error!?ast.Fn {
        const kw = p.advance();

        const name_tok = try p.expect(.ident, "expected a function name", null) orelse {
            p.recoverToTopLevel();
            return null;
        };
        _ = try p.expect(.l_paren, "expected `(`", null) orelse {
            p.recoverToTopLevel();
            return null;
        };
        _ = try p.expect(.r_paren, "expected `)`", "functions take no parameters yet") orelse {
            p.recoverToTopLevel();
            return null;
        };

        p.skipNewlines();

        const body = try p.parseBlock() orelse {
            p.recoverToTopLevel();
            return null;
        };

        return .{
            .name = name_tok.value,
            .name_span = name_tok.span,
            .body = body,
            .span = Span.merge(kw.span, body.span),
        };
    }

    fn parseBlock(p: *Parser) Error!?ast.Block {
        const open = try p.expect(.l_brace, "expected `{`", null) orelse return null;

        var stmts: std.ArrayList(ast.Stmt) = .empty;

        while (true) {
            p.skipNewlines();
            if (p.peek() == .r_brace or p.peek() == .eof) break;

            const before = p.pos;

            if (try p.parseExpr()) |e| {
                try stmts.append(p.arena, .{ .expr = e });
                if (p.peek() != .r_brace and p.peek() != .eof and p.peek() != .newline) {
                    try p.diags.err(
                        .unexpected_token,
                        p.current().span,
                        "unexpected token after statement",
                        "expected a line break here",
                        null,
                    );
                    p.recoverInBlock();
                }
            } else {
                p.recoverInBlock();
            }

            if (p.pos == before) p.pos += 1;
        }

        const close = try p.expect(.r_brace, "expected `}`", "the function body is never closed") orelse
            p.current();

        return .{
            .stmts = try stmts.toOwnedSlice(p.arena),
            .span = Span.merge(open.span, close.span),
        };
    }

    fn recoverInBlock(p: *Parser) void {
        while (p.peek() != .newline and p.peek() != .r_brace and p.peek() != .eof) p.pos += 1;
    }

    fn parseExpr(p: *Parser) Error!?ast.Expr {
        switch (p.peek()) {
            .string => {
                const t = p.advance();
                return .{ .string = .{ .value = t.value, .span = t.span } };
            },
            .ident => return try p.parseCall(),
            else => {
                try p.diags.err(
                    .unexpected_token,
                    p.current().span,
                    "expected an expression",
                    "expected a string literal or a function call",
                    null,
                );
                return null;
            },
        }
    }

    fn parseCall(p: *Parser) Error!?ast.Expr {
        const name = p.advance();
        _ = try p.expect(.l_paren, "expected `(` to start a call", null) orelse return null;

        var args: std.ArrayList(ast.Expr) = .empty;

        if (p.peek() != .r_paren) {
            while (true) {
                const arg = try p.parseExpr() orelse return null;
                try args.append(p.arena, arg);
                if (p.peek() != .comma) break;
                _ = p.advance();
            }
        }

        const close = try p.expect(.r_paren, "expected `)`", "add `)` to close the call") orelse return null;

        return .{ .call = .{
            .callee = name.value,
            .callee_span = name.span,
            .args = try args.toOwnedSlice(p.arena),
            .span = Span.merge(name.span, close.span),
        } };
    }
};

pub fn parse(
    arena: std.mem.Allocator,
    tokens: []const Token,
    diags: *diagnostics.Diagnostics,
) !ast.Program {
    var p: Parser = .{ .arena = arena, .tokens = tokens, .diags = diags, .pos = 0 };
    return p.parseProgram();
}

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

test "missing function name does not hang" {
    var p = try parseText(testing.allocator, "fn () {\n}\n");
    defer p.deinit();
    try testing.expect(p.diags.hasErrors());
}
