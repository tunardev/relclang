const std = @import("std");
const source = @import("../../support/source.zig");
const diagnostics = @import("../../support/diagnostics.zig");
const ast = @import("../../syntax/ast.zig");
const tir = @import("../../ir/tir.zig");
const types = @import("../types.zig");
const resolve = @import("../resolve.zig");
const typecheck = @import("../type_rules.zig");

const Span = source.Span;
const Type = types.Type;

const Error = @import("context.zig").Error;

pub const Instance = struct {
    ast_index: usize,
    args: []const Type,
    tir_index: usize,
};

pub const Job = struct {
    ast_index: usize,
    args: []const Type,
    tir_index: usize,
};

pub const Mono = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    symbols: *resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
    program: ast.Program,
    functions: std.ArrayList(tir.Function),
    ast_to_tir: []?usize,
    instances: std.ArrayList(Instance),
    pending: std.ArrayList(Job),

    pub fn find(m: *Mono, ast_index: usize, args: []const Type) ?usize {
        outer: for (m.instances.items) |inst| {
            if (inst.ast_index != ast_index) continue;
            if (inst.args.len != args.len) continue;
            for (inst.args, args) |a, b| {
                if (!Type.eql(a, b)) continue :outer;
            }
            return inst.tir_index;
        }
        return null;
    }

    pub fn instantiate(m: *Mono, ast_index: usize, args: []const Type) Error!usize {
        if (m.find(ast_index, args)) |index| return index;

        const tir_index = m.functions.items.len;
        try m.functions.append(m.arena, undefined);

        const owned = try m.arena.dupe(Type, args);
        try m.instances.append(m.gpa, .{
            .ast_index = ast_index,
            .args = owned,
            .tir_index = tir_index,
        });
        try m.pending.append(m.gpa, .{
            .ast_index = ast_index,
            .args = owned,
            .tir_index = tir_index,
        });

        return tir_index;
    }
};
