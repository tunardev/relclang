const std = @import("std");
const source = @import("source.zig");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const lower = @import("lower.zig");
const ownership = @import("ownership.zig");
const backend = @import("backend/zig.zig");
const runtime = @import("backend/runtime.zig");

pub const Result = struct {
    zig_source: []const u8,
    runtime_source: []const u8,
    runtime_name: []const u8,
};

pub fn toZig(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    file: source.SourceFile,
    diags: *diagnostics.Diagnostics,
) !?Result {
    const tokens = try lexer.tokenize(arena, file, diags);
    if (diags.hasErrors()) return null;

    const program = try parser.parse(arena, tokens, diags);
    if (diags.hasErrors()) return null;

    var symbols = try resolve.run(arena, gpa, program, diags);
    defer symbols.deinit();
    if (diags.hasErrors()) return null;

    const typed = try lower.run(arena, gpa, program, &symbols, diags);
    if (diags.hasErrors()) return null;

    try ownership.check(gpa, typed, diags);
    if (diags.hasErrors()) return null;

    return .{
        .zig_source = try backend.emit(arena, typed),
        .runtime_source = runtime.source,
        .runtime_name = runtime.file_name,
    };
}

const testing = std.testing;

test "hello world compiles to zig" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const file: source.SourceFile = .{
        .path = "hello.rls",
        .text = "fn main() {\n    println(\"Hello, Relastic!\")\n}\n",
    };

    const result = try toZig(arena_state.allocator(), gpa, file, &d);
    try testing.expect(result != null);
    try testing.expect(!d.hasErrors());
    try testing.expect(std.mem.indexOf(u8, result.?.zig_source, "rc_main") != null);
    try testing.expectEqualStrings("relastic_rt.zig", result.?.runtime_name);
}

test "a lexer error stops the pipeline before parsing" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "fn main() {\n    $\n}\n" };
    const result = try toZig(arena_state.allocator(), gpa, file, &d);

    try testing.expect(result == null);
    try testing.expectEqual(diagnostics.Code.unexpected_char, d.list.items[0].code.?);
}

test "a parse error stops the pipeline before resolving" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "fn main() {\n    println(\"hi\"\n}\n" };
    const result = try toZig(arena_state.allocator(), gpa, file, &d);

    try testing.expect(result == null);
    try testing.expectEqual(diagnostics.Code.unexpected_token, d.list.items[0].code.?);
}

test "a resolve error stops the pipeline before type checking" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "fn main() {\n    nope()\n}\n" };
    const result = try toZig(arena_state.allocator(), gpa, file, &d);

    try testing.expect(result == null);
    try testing.expectEqual(diagnostics.Code.unknown_function, d.list.items[0].code.?);
}

test "a type error stops the pipeline before lowering" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var d: diagnostics.Diagnostics = .init(gpa);
    defer d.deinit();

    const file: source.SourceFile = .{ .path = "t.rls", .text = "fn main() {\n    println(\"a\", \"b\")\n}\n" };
    const result = try toZig(arena_state.allocator(), gpa, file, &d);

    try testing.expect(result == null);
    try testing.expectEqual(diagnostics.Code.wrong_arg_count, d.list.items[0].code.?);
}
