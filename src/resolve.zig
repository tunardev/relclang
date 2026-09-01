const std = @import("std");
const source = @import("source.zig");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const types = @import("types.zig");

pub const Builtin = enum {
    println,

    pub fn arity(b: Builtin) usize {
        return switch (b) {
            .println => 1,
        };
    }

    pub fn resultType(b: Builtin) types.Type {
        return switch (b) {
            .println => .void,
        };
    }

    pub fn accepts(b: Builtin, index: usize, ty: types.Type) bool {
        return switch (b) {
            .println => index == 0 and (ty == .str or ty == .int),
        };
    }

    pub fn describeParam(b: Builtin, index: usize) []const u8 {
        return switch (b) {
            .println => if (index == 0) "`Str` or `Int`" else "nothing",
        };
    }
};

pub const Symbol = union(enum) {
    builtin: Builtin,
    function: usize,
};

pub const SymbolTable = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Symbol),
    entry: ?usize,

    pub fn lookup(t: *const SymbolTable, name: []const u8) ?Symbol {
        return t.map.get(name);
    }

    pub fn deinit(t: *SymbolTable) void {
        t.map.deinit(t.gpa);
    }
};

const entry_name = "main";

pub fn run(
    gpa: std.mem.Allocator,
    program: ast.Program,
    diags: *diagnostics.Diagnostics,
) !SymbolTable {
    var table: SymbolTable = .{ .gpa = gpa, .map = .empty, .entry = null };
    errdefer table.deinit();

    inline for (@typeInfo(Builtin).@"enum".fields) |field| {
        try table.map.put(gpa, field.name, .{ .builtin = @field(Builtin, field.name) });
    }

    for (program.fns, 0..) |f, index| {
        if (table.map.get(f.name)) |existing| {
            const message = switch (existing) {
                .builtin => "a builtin with this name already exists",
                .function => "this function is already defined",
            };
            try diags.err(.duplicate_function, f.name_span, message, "duplicate definition", null);
            continue;
        }
        try table.map.put(gpa, f.name, .{ .function = index });
        if (std.mem.eql(u8, f.name, entry_name)) table.entry = index;
    }

    if (table.entry == null) {
        try diags.err(
            .missing_main,
            null,
            "no `main` function found",
            null,
            "every Relastic program needs `fn main() { ... }`",
        );
    }

    return table;
}

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
    const symbols = try run(gpa, program, &d);
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
