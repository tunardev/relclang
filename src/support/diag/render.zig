const std = @import("std");
const source = @import("../source.zig");
const model = @import("model.zig");

const Span = source.Span;
const SourceFile = source.SourceFile;
const Diagnostic = model.Diagnostic;

pub fn digits(n: u32) usize {
    var count: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) count += 1;
    return count;
}

pub fn renderOne(item: Diagnostic, file: SourceFile, w: *std.Io.Writer) !void {
    const span = item.span orelse return renderFileLevel(item, file, w);
    const loc = file.locOf(span.start);
    const line_text = file.lineText(loc.line);
    const gutter = digits(loc.line) + 1;

    try w.writeAll(item.severity.text());
    if (item.code) |c| try w.print("[{s}]", .{c.id()});
    try w.print(": {s}\n\n", .{item.message});

    try w.splatByteAll(' ', gutter);
    try w.print("--> {s}:{d}:{d}\n", .{ file.path, loc.line, loc.col });

    try w.splatByteAll(' ', gutter + 1);
    try w.writeAll("|\n");

    try w.print(" {d} | ", .{loc.line});
    for (line_text) |ch| try w.writeByte(if (ch == '\t') ' ' else ch);
    try w.writeByte('\n');

    try w.splatByteAll(' ', gutter + 1);
    try w.writeAll("| ");
    try w.splatByteAll(' ', loc.col - 1);

    const remaining = line_text.len + 1 -| (loc.col - 1);
    const width = @max(@as(usize, 1), @min(span.len(), remaining));
    try w.splatByteAll('^', width);

    if (item.label) |l| try w.print(" {s}", .{l});
    try w.writeByte('\n');

    try w.splatByteAll(' ', gutter + 1);
    try w.writeAll("|\n");

    if (item.help) |h| try w.print("help: {s}\n", .{h});
    try w.writeByte('\n');
}

pub fn renderFileLevel(item: Diagnostic, file: SourceFile, w: *std.Io.Writer) !void {
    try w.writeAll(item.severity.text());
    if (item.code) |c| try w.print("[{s}]", .{c.id()});
    try w.print(": {s}\n\n", .{item.message});
    try w.print("  --> {s}\n", .{file.path});
    if (item.help) |h| try w.print("\nhelp: {s}\n", .{h});
    try w.writeByte('\n');
}
