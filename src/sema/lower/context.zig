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



pub const Error = error{OutOfMemory};

pub const Binding = struct {
    name: []const u8,
    slot: u32,
    ty: Type,
    depth: u32,
};

pub const Place = struct {
    slot: u32,
    is_mut: bool,
    name: []const u8,
};

pub const Fn = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    symbols: *resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
    mono: *@import("mono.zig").Mono,
    ret_ty: Type,
    type_args: []const Type,
    expected: ?Type,
    bindings: std.ArrayList(Binding),
    locals: std.ArrayList(tir.Local),
    depth: u32,

    pub fn subst(f: *Fn, ty: Type) Error!Type {
        if (f.type_args.len == 0) return ty;
        return types.substitute(f.arena, ty, f.type_args);
    }

    pub fn deinit(f: *Fn) void {
        f.bindings.deinit(f.gpa);
    }

    pub fn lookup(f: *Fn, name: []const u8) ?Binding {
        var i = f.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, f.bindings.items[i].name, name)) return f.bindings.items[i];
        }
        return null;
    }

    pub fn declaredAtDepth(f: *Fn, name: []const u8) bool {
        for (f.bindings.items) |b| {
            if (b.depth == f.depth and std.mem.eql(u8, b.name, name)) return true;
        }
        return false;
    }

    pub fn declare(f: *Fn, name: []const u8, ty: Type) Error!u32 {
        return f.declareMut(name, ty, false);
    }

    pub fn declareMut(f: *Fn, name: []const u8, ty: Type, is_mut: bool) Error!u32 {
        const slot: u32 = @intCast(f.locals.items.len);
        try f.locals.append(f.arena, .{
            .name = name,
            .ty = ty,
            .used = false,
            .is_mut = is_mut,
            .assigned = false,
        });
        try f.bindings.append(f.gpa, .{ .name = name, .slot = slot, .ty = ty, .depth = f.depth });
        return slot;
    }

    pub fn tyName(f: *Fn, ty: Type) Error![]const u8 {
        return f.symbols.typeName(f.diags.arena.allocator(), ty) catch error.OutOfMemory;
    }

    pub fn box(f: *Fn, e: tir.Expr) Error!*const tir.Expr {
        const ptr = try f.arena.create(tir.Expr);
        ptr.* = e;
        return ptr;
    }
};
