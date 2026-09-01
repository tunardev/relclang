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
    name: []const u8,
    ret_ty: Type,
    param_count: u32,
    type_args: []const Type,
    expected: ?Type,
    temps: std.ArrayList(tir.Stmt),
    bindings: std.ArrayList(Binding),
    locals: std.ArrayList(tir.Local),
    depth: u32,

    pub fn subst(f: *Fn, ty: Type) Error!Type {
        if (f.type_args.len == 0) return ty;
        return types.substitute(f.arena, ty, f.type_args);
    }

    pub fn deinit(f: *Fn) void {
        f.bindings.deinit(f.gpa);
        f.temps.deinit(f.gpa);
    }

    pub fn escapingLocal(f: *Fn, value: tir.Expr) ?u32 {
        const slot = f.refRoot(value) orelse return null;
        return if (slot >= f.param_count) slot else null;
    }

    pub fn refRoot(f: *Fn, value: tir.Expr) ?u32 {
        switch (value) {
            .borrow => |b| return f.rootSlotOf(b.operand.*),
            .local_ref => |l| return if (l.ty.isInvalid()) null else f.locals.items[l.slot].borrows_local,
            .deref => |d| return f.refRoot(d.operand.*),
            .vec_op => |v| return if (v.ty == .ref and v.args.len > 0) f.rootSlotOf(v.args[0]) else null,
            .if_expr => |node| {
                const then_root = if (node.then_block.result) |r| f.refRoot(r.*) else null;
                const else_root = if (node.else_block) |b| (if (b.result) |r| f.refRoot(r.*) else null) else null;
                return f.preferLocal(then_root, else_root);
            },
            .match => |m| {
                var found: ?u32 = null;
                for (m.arms) |arm| found = f.preferLocal(found, f.refRoot(arm.body));
                return found;
            },
            .call_function => |c| {
                if (!types.hasReference(c.ty)) return null;
                var found: ?u32 = null;
                for (c.args) |arg| found = f.preferLocal(found, f.refRoot(arg));
                return found;
            },
            else => return null,
        }
    }

    fn preferLocal(f: *Fn, a: ?u32, b: ?u32) ?u32 {
        if (a) |slot| if (slot >= f.param_count) return slot;
        if (b) |slot| if (slot >= f.param_count) return slot;
        return a orelse b;
    }

    pub fn checkEscape(f: *Fn, value: tir.Expr, fn_name: []const u8) Error!void {
        if (!types.hasReference(f.ret_ty)) return;
        const slot = f.escapingLocal(value) orelse return;
        try f.diags.err(
            .escaping_reference,
            value.spanOf(),
            try f.diags.fmt("this reference points at `{s}`, which is local to `{s}`", .{
                f.locals.items[slot].name,
                fn_name,
            }),
            "the value is gone once the function returns",
            "return the value itself, or take the reference as a parameter",
        );
    }

    pub fn rootSlotOf(f: *Fn, value: tir.Expr) ?u32 {
        return switch (value) {
            .local_ref => |l| if (l.ty.isInvalid()) null else l.slot,
            .field => |x| f.rootSlotOf(x.base.*),
            .index => |x| f.rootSlotOf(x.base.*),
            .deref => |d| f.rootSlotOf(d.operand.*),
            .borrow => |b| f.rootSlotOf(b.operand.*),
            else => null,
        };
    }

    pub fn hoistOwning(f: *Fn, value: tir.Expr) Error!tir.Expr {
        const ty = value.typeOf();
        if (!types.needsDrop(ty, f.symbols.registry())) return value;

        switch (value) {
            .local_ref, .field, .index, .deref, .borrow => return value,
            else => {},
        }

        const slot: u32 = @intCast(f.locals.items.len);
        try f.locals.append(f.arena, .{
            .name = "tmp",
            .ty = ty,
            .used = true,
            .is_mut = false,
            .assigned = false,
        });

        try f.temps.append(f.gpa, .{ .let = .{
            .slot = slot,
            .init = value,
            .ty = ty,
            .span = value.spanOf(),
        } });

        return .{ .local_ref = .{ .slot = slot, .ty = ty, .span = value.spanOf() } };
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
