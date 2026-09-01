const std = @import("std");
const source = @import("source.zig");
const model = @import("diag/model.zig");
const render = @import("diag/render.zig");

const Span = source.Span;
const SourceFile = source.SourceFile;

pub const Code = model.Code;
pub const Severity = model.Severity;
pub const Diagnostic = model.Diagnostic;

const renderOne = render.renderOne;

pub const Diagnostics = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(Diagnostic),
    errors: usize,

    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        return .{ .gpa = gpa, .arena = .init(gpa), .list = .empty, .errors = 0 };
    }

    pub fn deinit(d: *Diagnostics) void {
        d.list.deinit(d.gpa);
        d.arena.deinit();
    }

    pub fn fmt(d: *Diagnostics, comptime template: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(d.arena.allocator(), template, args);
    }

    pub fn add(d: *Diagnostics, item: Diagnostic) !void {
        if (item.severity == .err) d.errors += 1;
        try d.list.append(d.gpa, item);
    }

    pub fn err(
        d: *Diagnostics,
        code: Code,
        span: ?Span,
        message: []const u8,
        label: ?[]const u8,
        help: ?[]const u8,
    ) !void {
        try d.add(.{
            .severity = .err,
            .code = code,
            .message = message,
            .span = span,
            .label = label,
            .help = help,
        });
    }

    pub fn hasErrors(d: *const Diagnostics) bool {
        return d.errors > 0;
    }

    pub fn render(d: *const Diagnostics, file: SourceFile, w: *std.Io.Writer) !void {
        for (d.list.items) |item| try renderOne(item, file, w);
    }
};
