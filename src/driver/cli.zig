const std = @import("std");
const source = @import("../support/source.zig");
const diagnostics = @import("../support/diagnostics.zig");
const compile = @import("pipeline.zig");

pub const version = "0.1.0";

const cache_dir = ".relastic";

const usage =
    \\relc - the Relastic compiler
    \\
    \\usage:
    \\  relc build <file.rls> [-o <name>]
    \\  relc run <file.rls>
    \\  relc check <file.rls>
    \\  relc emit-zig <file.rls>
    \\  relc version
    \\
;

const Command = enum { build, run, check, emit_zig, version };

pub fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const [:0]const u8,
) !u8 {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;
    defer w.flush() catch {};

    var err_buf: [4096]u8 = undefined;
    var errw = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const e = &errw.interface;
    defer e.flush() catch {};

    if (argv.len < 2) {
        try e.writeAll(usage);
        return 1;
    }

    const command = parseCommand(argv[1]) orelse {
        try e.print("unknown command `{s}`\n\n", .{argv[1]});
        try e.writeAll(usage);
        return 1;
    };

    if (command == .version) {
        try w.print("relc {s}\n", .{version});
        return 0;
    }

    if (argv.len < 3) {
        try e.print("`{s}` needs a source file\n\n", .{argv[1]});
        try e.writeAll(usage);
        return 1;
    }

    const path = argv[2];

    if (!std.mem.endsWith(u8, path, ".rls")) {
        try e.print("`{s}` is not a .rls file\n", .{path});
        return 1;
    }

    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch |err| {
        try e.print("cannot read `{s}`: {s}\n", .{ path, @errorName(err) });
        return 1;
    };

    const file: source.SourceFile = .{ .path = path, .text = text };

    var diags: diagnostics.Diagnostics = .init(gpa);
    defer diags.deinit();

    const result = try compile.toZig(arena, gpa, file, &diags);

    if (result == null) {
        try diags.render(file, e);
        try e.print("compilation failed with {d} error(s)\n", .{diags.errors});
        return 1;
    }

    const compiled = result.?;

    if (command == .check) {
        try w.print("{s}: no errors\n", .{path});
        return 0;
    }

    if (command == .emit_zig) {
        try w.writeAll(compiled.zig_source);
        return 0;
    }

    const stem = stemOf(path);
    const output_name = parseOutputName(argv) orelse stem;

    const exe_path = if (command == .run)
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ cache_dir, stem })
    else
        try std.fmt.allocPrint(arena, "./{s}", .{output_name});

    const zig_name = try std.fmt.allocPrint(arena, "{s}.zig", .{stem});

    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch |err| {
        try e.print("cannot create `{s}`: {s}\n", .{ cache_dir, @errorName(err) });
        return 1;
    };

    var dir = std.Io.Dir.cwd().openDir(io, cache_dir, .{}) catch |err| {
        try e.print("cannot open `{s}`: {s}\n", .{ cache_dir, @errorName(err) });
        return 1;
    };
    defer dir.close(io);

    try dir.writeFile(io, .{ .sub_path = zig_name, .data = compiled.zig_source });
    try dir.writeFile(io, .{ .sub_path = compiled.runtime_name, .data = compiled.runtime_source });

    const zig_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ cache_dir, zig_name });
    const emit_flag = try std.fmt.allocPrint(arena, "-femit-bin={s}", .{exe_path});

    const zig_result = std.process.run(arena, io, .{
        .argv = &.{ "zig", "build-exe", zig_path, emit_flag },
    }) catch |err| {
        try e.print("cannot run the zig compiler: {s}\n", .{@errorName(err)});
        try e.writeAll("relc needs `zig` on your PATH\n");
        return 1;
    };

    const failed = switch (zig_result.term) {
        .exited => |code| code != 0,
        else => true,
    };

    if (failed) {
        try e.writeAll(zig_result.stderr);
        try e.writeAll("the generated zig failed to compile\n");
        return 1;
    }

    if (command == .build) {
        try w.print("built {s}\n", .{output_name});
        return 0;
    }

    try w.flush();

    const app = std.process.run(arena, io, .{ .argv = &.{exe_path} }) catch |err| {
        try e.print("cannot run `{s}`: {s}\n", .{ exe_path, @errorName(err) });
        return 1;
    };

    try w.writeAll(app.stdout);
    try e.writeAll(app.stderr);

    return switch (app.term) {
        .exited => |code| code,
        else => 1,
    };
}

fn parseCommand(text: []const u8) ?Command {
    if (std.mem.eql(u8, text, "build")) return .build;
    if (std.mem.eql(u8, text, "run")) return .run;
    if (std.mem.eql(u8, text, "check")) return .check;
    if (std.mem.eql(u8, text, "emit-zig")) return .emit_zig;
    if (std.mem.eql(u8, text, "version")) return .version;
    return null;
}

fn parseOutputName(argv: []const [:0]const u8) ?[]const u8 {
    var i: usize = 3;
    while (i + 1 < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-o")) return argv[i + 1];
    }
    return null;
}

fn stemOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return base[0..dot];
}

const testing = std.testing;

test "stem strips directories and extension" {
    try testing.expectEqualStrings("hello", stemOf("examples/hello.rls"));
    try testing.expectEqualStrings("hello", stemOf("hello.rls"));
    try testing.expectEqualStrings("hello", stemOf("/a/b/hello.rls"));
}

test "parses every command name" {
    try testing.expectEqual(Command.build, parseCommand("build").?);
    try testing.expectEqual(Command.run, parseCommand("run").?);
    try testing.expectEqual(Command.check, parseCommand("check").?);
    try testing.expectEqual(Command.emit_zig, parseCommand("emit-zig").?);
    try testing.expectEqual(Command.version, parseCommand("version").?);
    try testing.expect(parseCommand("nope") == null);
}

test "output name defaults to none without -o" {
    const argv = [_][:0]const u8{ "relc", "build", "a.rls" };
    try testing.expect(parseOutputName(&argv) == null);
}

test "output name is read from -o" {
    const argv = [_][:0]const u8{ "relc", "build", "a.rls", "-o", "custom" };
    try testing.expectEqualStrings("custom", parseOutputName(&argv).?);
}
