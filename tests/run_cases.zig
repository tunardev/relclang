const std = @import("std");
const relastic = @import("relastic");

const source = relastic.source;
const diagnostics = relastic.diagnostics;
const compile = relastic.compile;

const build_options = @import("build_options");

const err_dir = "tests/cases/err";
const ok_dir = "tests/cases/ok";
const showcase_rls = "examples/showcase.rls";
const showcase_zig = "examples/showcase.generated.zig";

fn renderCase(gpa: std.mem.Allocator, path: []const u8, text: []const u8) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var diags: diagnostics.Diagnostics = .init(gpa);
    defer diags.deinit();

    const file: source.SourceFile = .{ .path = path, .text = text };
    _ = try compile.toZig(arena_state.allocator(), gpa, file, &diags);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try diags.render(file, &aw.writer);
    return aw.toOwnedSlice();
}

test "error cases match their golden output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, err_dir, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    var failures: usize = 0;
    var checked: usize = 0;

    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".rls")) continue;

        const text = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(text);

        const rendered = try renderCase(gpa, entry.name, text);
        defer gpa.free(rendered);

        if (rendered.len == 0) {
            std.debug.print("case {s} produced no diagnostics\n", .{entry.name});
            failures += 1;
            continue;
        }

        const golden_name = try std.fmt.allocPrint(gpa, "{s}.expected", .{entry.name[0 .. entry.name.len - 4]});
        defer gpa.free(golden_name);

        if (build_options.update_goldens) {
            try dir.writeFile(io, .{ .sub_path = golden_name, .data = rendered });
            checked += 1;
            continue;
        }

        const golden = dir.readFileAlloc(io, golden_name, gpa, .limited(1 << 20)) catch {
            std.debug.print("missing golden file: {s}\n", .{golden_name});
            failures += 1;
            continue;
        };
        defer gpa.free(golden);

        if (!std.mem.eql(u8, golden, rendered)) {
            std.debug.print("mismatch in {s}\n--- expected ---\n{s}\n--- actual ---\n{s}\n", .{ entry.name, golden, rendered });
            failures += 1;
        }
        checked += 1;
    }

    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expect(checked > 0);
}

test "ok cases build and produce the expected output" {
    if (build_options.update_goldens) return;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, ok_dir, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    var checked: usize = 0;

    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".rls")) continue;

        const rls_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ok_dir, entry.name });
        defer gpa.free(rls_path);

        const result = try std.process.run(gpa, io, .{
            .argv = &.{ "./zig-out/bin/relc", "run", rls_path },
        });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("relc run failed for {s}:\n{s}\n", .{ entry.name, result.stderr });
            return error.RelcFailed;
        }

        if (result.stderr.len != 0) {
            std.debug.print("{s} wrote to stderr:\n{s}\n", .{ entry.name, result.stderr });
            return error.UnexpectedStderr;
        }

        const out_name = try std.fmt.allocPrint(gpa, "{s}.out", .{entry.name[0 .. entry.name.len - 4]});
        defer gpa.free(out_name);

        const expected = try dir.readFileAlloc(io, out_name, gpa, .limited(1 << 20));
        defer gpa.free(expected);

        try std.testing.expectEqualStrings(expected, result.stdout);
        checked += 1;
    }

    try std.testing.expect(checked > 0);
}

test "the published showcase output matches the compiler" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const text = try std.Io.Dir.cwd().readFileAlloc(io, showcase_rls, gpa, .limited(1 << 20));
    defer gpa.free(text);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var diags: diagnostics.Diagnostics = .init(gpa);
    defer diags.deinit();

    const file: source.SourceFile = .{ .path = showcase_rls, .text = text };
    const result = try compile.toZig(arena_state.allocator(), gpa, file, &diags);

    if (result == null) {
        std.debug.print("{s} does not compile\n", .{showcase_rls});
        return error.ShowcaseBroken;
    }

    if (build_options.update_goldens) {
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = showcase_zig,
            .data = result.?.zig_source,
        });
        return;
    }

    const published = try std.Io.Dir.cwd().readFileAlloc(io, showcase_zig, gpa, .limited(1 << 20));
    defer gpa.free(published);

    try std.testing.expectEqualStrings(published, result.?.zig_source);
}
