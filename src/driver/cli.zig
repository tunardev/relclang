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
    \\  relc build <file.rls> [-o <name>] [--release]
    \\  relc run <file.rls>
    \\  relc check <file.rls>
    \\  relc emit-zig <file.rls>
    \\  relc version
    \\
;

const Command = enum { build, run, check, emit_zig, version };

pub const Options = struct {
    command: Command,
    path: []const u8 = "",
    output: ?[]const u8 = null,
    release: bool = false,
};

pub const ParseError = error{ MissingCommand, UnknownCommand, MissingFile, NotRls, MissingOutputName, UnknownOption };

pub fn parseArgs(argv: []const [:0]const u8) ParseError!Options {
    if (argv.len < 2) return error.MissingCommand;
    const command = parseCommand(argv[1]) orelse return error.UnknownCommand;
    if (command == .version) return .{ .command = command };
    if (argv.len < 3) return error.MissingFile;

    var opts: Options = .{ .command = command, .path = argv[2] };
    if (!std.mem.endsWith(u8, opts.path, ".rls")) return error.NotRls;

    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--release")) {
            opts.release = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            if (i + 1 >= argv.len) return error.MissingOutputName;
            i += 1;
            opts.output = argv[i];
        } else {
            return error.UnknownOption;
        }
    }
    return opts;
}

fn offendingOption(argv: []const [:0]const u8) []const u8 {
    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--release")) continue;
        if (std.mem.eql(u8, argv[i], "-o")) {
            i += 1;
            continue;
        }
        return argv[i];
    }
    return "";
}

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

    const opts = parseArgs(argv) catch |err| {
        switch (err) {
            error.MissingCommand => try e.writeAll(usage),
            error.UnknownCommand => {
                try e.print("unknown command `{s}`\n\n", .{argv[1]});
                try e.writeAll(usage);
            },
            error.MissingFile => {
                try e.print("`{s}` needs a source file\n\n", .{argv[1]});
                try e.writeAll(usage);
            },
            error.NotRls => try e.print("`{s}` is not a .rls file\n", .{argv[2]}),
            error.MissingOutputName => try e.writeAll("`-o` needs an output name\n"),
            error.UnknownOption => {
                try e.print("unknown option `{s}`\n\n", .{offendingOption(argv)});
                try e.writeAll(usage);
            },
        }
        return 1;
    };

    if (opts.command == .version) {
        try w.print("relc {s}\n", .{version});
        return 0;
    }

    const path = opts.path;

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

    if (opts.command == .check) {
        try w.print("{s}: no errors\n", .{path});
        return 0;
    }

    if (opts.command == .emit_zig) {
        try w.writeAll(compiled.zig_source);
        return 0;
    }

    const stem = stemOf(path);
    const output_name = opts.output orelse stem;

    const exe_path = if (opts.command == .run)
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ cache_dir, stem })
    else
        output_name;

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

    const optimize = if (opts.release) "-OReleaseFast" else "-ODebug";

    const zig_result = std.process.run(arena, io, .{
        .argv = &.{ "zig", "build-exe", zig_path, emit_flag, optimize },
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

    if (opts.command == .build) {
        try w.print("built {s}\n", .{output_name});
        return 0;
    }

    try w.flush();
    try e.flush();

    var app = std.process.spawn(io, .{ .argv = &.{exe_path} }) catch |err| {
        try e.print("cannot run `{s}`: {s}\n", .{ exe_path, @errorName(err) });
        return 1;
    };

    const term = app.wait(io) catch |err| {
        try e.print("cannot wait for `{s}`: {s}\n", .{ exe_path, @errorName(err) });
        return 1;
    };

    return switch (term) {
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

test "parses a plain build command" {
    const argv = [_][:0]const u8{ "relc", "build", "a.rls" };
    const opts = try parseArgs(&argv);
    try testing.expectEqual(Command.build, opts.command);
    try testing.expectEqualStrings("a.rls", opts.path);
    try testing.expect(opts.output == null);
    try testing.expect(!opts.release);
}

test "release and output can be given in any order" {
    const argv = [_][:0]const u8{ "relc", "build", "a.rls", "--release", "-o", "out" };
    const opts = try parseArgs(&argv);
    try testing.expect(opts.release);
    try testing.expectEqualStrings("out", opts.output.?);

    const swapped = [_][:0]const u8{ "relc", "build", "a.rls", "-o", "out", "--release" };
    const opts2 = try parseArgs(&swapped);
    try testing.expect(opts2.release);
    try testing.expectEqualStrings("out", opts2.output.?);
}

test "an output flag without a name is rejected" {
    const argv = [_][:0]const u8{ "relc", "build", "a.rls", "-o" };
    try testing.expectError(error.MissingOutputName, parseArgs(&argv));
}

test "an unknown option is rejected" {
    const argv = [_][:0]const u8{ "relc", "build", "a.rls", "--fast" };
    try testing.expectError(error.UnknownOption, parseArgs(&argv));
    try testing.expectEqualStrings("--fast", offendingOption(&argv));
}

test "version needs no file" {
    const argv = [_][:0]const u8{ "relc", "version" };
    const opts = try parseArgs(&argv);
    try testing.expectEqual(Command.version, opts.command);
}

test "a source file must end in rls" {
    const argv = [_][:0]const u8{ "relc", "run", "a.txt" };
    try testing.expectError(error.NotRls, parseArgs(&argv));
}

test "a missing command or file is reported" {
    const none = [_][:0]const u8{"relc"};
    try testing.expectError(error.MissingCommand, parseArgs(&none));
    const no_file = [_][:0]const u8{ "relc", "run" };
    try testing.expectError(error.MissingFile, parseArgs(&no_file));
    const bad = [_][:0]const u8{ "relc", "nope", "a.rls" };
    try testing.expectError(error.UnknownCommand, parseArgs(&bad));
}
