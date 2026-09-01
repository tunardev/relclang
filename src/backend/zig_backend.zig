const std = @import("std");
const tir = @import("../ir/tir.zig");
const types = @import("../sema/types.zig");
const runtime = @import("runtime.zig");

const zig_types = @import("zig/types.zig");
const zig_stmt = @import("zig/stmt.zig");
const zig_expr = @import("zig/expr.zig");

const prefix = zig_types.prefix;
const Error = zig_types.Error;

const emitType = zig_types.emitType;
const emitBlockBody = zig_stmt.emitBlockBody;
const emitExpr = zig_expr.emitExpr;
const emitLocalName = zig_expr.emitLocalName;

pub fn emit(arena: std.mem.Allocator, program: tir.Program) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("const std = @import(\"std\");\n");
    try w.print("const rt = @import(\"{s}\");\n\n", .{runtime.file_name});

    for (program.enums, 0..) |def, index| {
        try w.print("const E{d}_{s} = union(enum) {{\n", .{ index, def.name });
        for (def.variants, 0..) |variant, vi| {
            try w.print("    v{d}_{s}: ", .{ vi, variant.name });
            if (variant.payload.len == 0) {
                try w.writeAll("void");
            } else {
                try w.writeAll("struct { ");
                for (variant.payload, 0..) |ty, fi| {
                    if (fi > 0) try w.writeAll(", ");
                    try w.print("f{d}: ", .{fi});
                    try emitType(w, program, ty);
                }
                try w.writeAll(" }");
            }
            try w.writeAll(",\n");
        }
        try w.writeAll("};\n\n");
    }

    for (program.structs, 0..) |def, index| {
        try w.print("const S{d}_{s} = struct {{\n", .{ index, def.name });
        for (def.fields, 0..) |field, i| {
            try w.print("    f{d}_{s}: ", .{ i, field.name });
            try emitType(w, program, field.ty);
            try w.writeAll(",\n");
        }
        try w.writeAll("};\n\n");
    }

    var entry: ?[]const u8 = null;
    var entry_takes_allocator = false;

    for (program.functions) |f| {
        try w.print("fn {s}{s}(", .{ prefix, f.name });
        for (0..f.param_count) |i| {
            if (i > 0) try w.writeAll(", ");
            if (types.needsDrop(f.locals[i].ty)) {
                try w.print("p{d}_{s}", .{ i, f.locals[i].name });
            } else {
                try emitLocalName(w, f, @intCast(i));
            }
            try w.writeAll(": ");
            try emitType(w, program, f.locals[i].ty);
        }
        try w.writeAll(") rt.Error!");
        try emitType(w, program, f.ret);
        try w.writeAll(" {\n");
        var lbl: u32 = 0;

        for (0..f.param_count) |i| {
            if (!types.needsDrop(f.locals[i].ty)) continue;
            try w.writeAll("    var ");
            try emitLocalName(w, f, @intCast(i));
            try w.print(" = p{d}_{s};\n", .{ i, f.locals[i].name });
            if (!f.locals[i].moved) {
                try w.writeAll("    defer ");
                try emitLocalName(w, f, @intCast(i));
                try w.writeAll(".deinit();\n");
            }
        }

        for (0..f.param_count) |i| {
            if (types.needsDrop(f.locals[i].ty)) continue;
            if (f.locals[i].used) continue;
            try w.writeAll("    _ = ");
            try emitLocalName(w, f, @intCast(i));
            try w.writeAll(";\n");
        }

        try emitBlockBody(w, program, f, &lbl, f.body, 1);
        if (f.body.result) |result| {
            try w.writeAll("    return ");
            try emitExpr(w, program, f, &lbl, result.*);
            try w.writeAll(";\n");
        }
        try w.writeAll("}\n\n");

        if (f.is_entry) {
            entry = f.name;
            entry_takes_allocator = f.param_count == 1 and f.locals[0].ty == .allocator;
        }
    }

    if (entry) |name| {
        try w.writeAll("pub fn main(init: std.process.Init) !void {\n");
        try w.writeAll("    rt.init(init.io);\n");
        if (entry_takes_allocator) {
            try w.print("    try {s}{s}(init.gpa);\n", .{ prefix, name });
        } else {
            try w.print("    try {s}{s}();\n", .{ prefix, name });
        }
        try w.writeAll("}\n");
    }

    return aw.written();
}
