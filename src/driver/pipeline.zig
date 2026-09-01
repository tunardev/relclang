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
