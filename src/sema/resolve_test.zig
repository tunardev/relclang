const std = @import("std");
const source = @import("../support/source.zig");
const diagnostics = @import("../support/diagnostics.zig");
const lexer = @import("../syntax/lexer.zig");
const parser = @import("../syntax/parser.zig");
const ast = @import("../syntax/ast.zig");
const types = @import("types.zig");
const typecheck = @import("type_rules.zig");
const symbols_mod = @import("symbols.zig");
const impl = @import("resolve.zig");

const Builtin = impl.Builtin;
const SymbolTable = impl.SymbolTable;
const run = impl.run;

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    diags: diagnostics.Diagnostics,
    symbols: SymbolTable,

    fn deinit(f: *Fixture) void {
        f.symbols.deinit();
        f.diags.deinit();
        f.arena.deinit();
    }
};

fn resolveText(gpa: std.mem.Allocator, text: []const u8) !Fixture {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    var d: diagnostics.Diagnostics = .init(gpa);
    const file: source.SourceFile = .{ .path = "t.rls", .text = text };
    const toks = try lexer.tokenize(arena_state.allocator(), file, &d);
    const program = try parser.parse(arena_state.allocator(), toks, &d);
    const symbols = try run(arena_state.allocator(), gpa, program, &d);
    return .{ .arena = arena_state, .diags = d, .symbols = symbols };
}

fn hasCode(d: diagnostics.Diagnostics, code: diagnostics.Code) bool {
    for (d.list.items) |item| {
        if (item.code == code) return true;
    }
    return false;
}

test "resolves main and the println builtin" {
    var f = try resolveText(testing.allocator, "fn main() {\n    println(\"hi\")\n}\n");
    defer f.deinit();

    try testing.expect(!f.diags.hasErrors());
    try testing.expectEqual(@as(?usize, 0), f.symbols.entry);
    try testing.expectEqual(Builtin.println, f.symbols.lookup("println").?.builtin);
    try testing.expectEqual(@as(usize, 0), f.symbols.lookup("main").?.function);
}

test "missing main reports E0005" {
    var f = try resolveText(testing.allocator, "fn other() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .missing_main));
}

test "duplicate function reports E0006" {
    var f = try resolveText(testing.allocator, "fn main() {\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .duplicate_function));
}

test "shadowing a builtin reports E0006" {
    var f = try resolveText(testing.allocator, "fn println() {\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .duplicate_function));
}

test "registers every declared function" {
    var f = try resolveText(testing.allocator, "fn helper() {\n}\nfn main() {\n    helper()\n}\n");
    defer f.deinit();
    try testing.expect(!f.diags.hasErrors());
    try testing.expectEqual(@as(usize, 0), f.symbols.lookup("helper").?.function);
    try testing.expectEqual(@as(usize, 1), f.symbols.lookup("main").?.function);
}

test "a function may be called before it is defined" {
    var f = try resolveText(testing.allocator, "fn main() {\n    helper()\n}\nfn helper() {\n}\n");
    defer f.deinit();
    try testing.expect(!f.diags.hasErrors());
}

test "entry index points at main even when it is not first" {
    var f = try resolveText(testing.allocator, "fn helper() {\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expectEqual(@as(?usize, 1), f.symbols.entry);
}

test "a recursive struct reports E0021" {
    var f = try resolveText(testing.allocator, "struct Node {\n    next: Node\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .recursive_struct));
}

test "a mutually recursive struct pair reports E0021" {
    var f = try resolveText(testing.allocator, "struct A {\n    b: B\n}\nstruct B {\n    a: A\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .recursive_struct));
}

test "a struct referring to another struct is fine" {
    var f = try resolveText(testing.allocator, "struct Inner {\n    v: Int\n}\nstruct Outer {\n    i: Inner\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(!f.diags.hasErrors());
}

test "a duplicate struct name is reported" {
    var f = try resolveText(testing.allocator, "struct P {\n    x: Int\n}\nstruct P {\n    y: Int\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .duplicate_function));
}

test "an unknown type in a signature reports E0018" {
    var f = try resolveText(testing.allocator, "fn f(a: Nope) {\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .unknown_struct));
}

test "self outside an impl reports E0017" {
    var f = try resolveText(testing.allocator, "fn foo(self) {\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .bad_signature));
}

test "a recursive struct is reported at its own name" {
    var f = try resolveText(testing.allocator, "struct W<T> {\n    x: T\n}\nstruct Node {\n    next: Node\n}\nfn main() {\n}\n");
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .recursive_struct));
    for (f.diags.list.items) |item| {
        if (item.code != .recursive_struct) continue;
        try testing.expectEqual(@as(u32, 32), item.span.?.start);
    }
}

const show_trait =
    \\struct P {
    \\    x: Int
    \\}
    \\trait Show {
    \\    fn show(self) -> Str
    \\    fn scale(self, by: Int) -> Int
    \\}
    \\
;

test "an impl method with the wrong return type reports E0017" {
    var f = try resolveText(testing.allocator, show_trait ++
        \\impl Show for P {
        \\    fn show(self) -> Int {
        \\        self.x
        \\    }
        \\    fn scale(self, by: Int) -> Int {
        \\        self.x * by
        \\    }
        \\}
        \\fn main() {
        \\}
        \\
    );
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .bad_signature));
}

test "an impl method with the wrong parameters reports E0017" {
    var f = try resolveText(testing.allocator, show_trait ++
        \\impl Show for P {
        \\    fn show(self) -> Str {
        \\        "p"
        \\    }
        \\    fn scale(self, by: Str) -> Int {
        \\        self.x
        \\    }
        \\}
        \\fn main() {
        \\}
        \\
    );
    defer f.deinit();
    try testing.expect(hasCode(f.diags, .bad_signature));
}

test "an impl method matching the trait is accepted" {
    var f = try resolveText(testing.allocator, show_trait ++
        \\impl Show for P {
        \\    fn show(self) -> Str {
        \\        "p"
        \\    }
        \\    fn scale(self, by: Int) -> Int {
        \\        self.x * by
        \\    }
        \\}
        \\fn main() {
        \\}
        \\
    );
    defer f.deinit();
    try testing.expect(!f.diags.hasErrors());
}
