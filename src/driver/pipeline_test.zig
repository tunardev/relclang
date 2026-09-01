const std = @import("std");
const source = @import("../support/source.zig");
const diagnostics = @import("../support/diagnostics.zig");
const lexer = @import("../syntax/lexer.zig");
const parser = @import("../syntax/parser.zig");
const resolve = @import("../sema/resolve.zig");
const lower = @import("../sema/lower.zig");
const ownership = @import("../sema/ownership.zig");
const backend = @import("../backend/zig_backend.zig");
const runtime = @import("../backend/runtime.zig");
const impl = @import("pipeline.zig");

const toZig = impl.toZig;

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
