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
        for (d.list.items) |existing| {
            if (sameDiagnostic(existing, item)) return;
        }
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

    fn sameDiagnostic(a: Diagnostic, b: Diagnostic) bool {
        if (a.severity != b.severity or a.code != b.code) return false;
        if (!sameSpan(a.span, b.span)) return false;
        return std.mem.eql(u8, a.message, b.message) and
            sameText(a.label, b.label) and
            sameText(a.help, b.help);
    }

    fn sameSpan(a: ?Span, b: ?Span) bool {
        if (a == null or b == null) return a == null and b == null;
        return a.?.start == b.?.start and a.?.end == b.?.end;
    }

    fn sameText(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?, b.?);
    }

    pub fn hasErrors(d: *const Diagnostics) bool {
        return d.errors > 0;
    }

    pub fn render(d: *const Diagnostics, file: SourceFile, w: *std.Io.Writer) !void {
        for (d.list.items) |item| try renderOne(item, file, w);
    }
};
