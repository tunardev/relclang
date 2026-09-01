const std = @import("std");
const source = @import("../support/source.zig");
const diagnostics = @import("../support/diagnostics.zig");
const tir = @import("../ir/tir.zig");
const types = @import("types.zig");

const Span = source.Span;

const Error = error{OutOfMemory};

const State = enum {
    undeclared,
    owned,
    moved,
};

const ActiveBorrow = struct {
    slot: u32,
    mutable: bool,
    temporary: bool,
    span: Span,
};

const Checker = struct {
    gpa: std.mem.Allocator,
    diags: *diagnostics.Diagnostics,
    structs: []const types.StructDef,
    enums: []const types.EnumDef,
    program: tir.Program,
    func: tir.Function,
    states: []State,
    moved_at: []Span,
    borrows: std.ArrayList(ActiveBorrow),
    persist_borrows: bool,

    fn borrowOf(c: *Checker, slot: u32) ?ActiveBorrow {
        for (c.borrows.items) |b| {
            if (b.slot == slot) return b;
        }
        return null;
    }

    fn exclusiveOf(c: *Checker, slot: u32) ?ActiveBorrow {
        for (c.borrows.items) |b| {
            if (b.slot == slot and b.mutable) return b;
        }
        return null;
    }

    fn rootSlot(c: *Checker, expr: tir.Expr) ?u32 {
        return switch (expr) {
            .local_ref => |l| l.slot,
            .field => |f| c.rootSlot(f.base.*),
            .index => |x| c.rootSlot(x.base.*),
            .deref => |d| c.rootSlot(d.operand.*),
            else => null,
        };
    }

    fn registerBorrow(c: *Checker, expr: tir.BorrowExpr) Error!void {
        const slot = c.rootSlot(expr.operand.*) orelse return;
        const local = c.func.locals[slot];

        if (expr.mutable) {
            if (c.borrowOf(slot)) |existing| {
                try c.diags.err(
                    .borrow_conflict,
                    expr.span,
                    try c.diags.fmt("cannot borrow `{s}` mutably", .{local.name}),
                    if (existing.mutable) "it is already borrowed mutably" else "it is already borrowed",
                    "a mutable borrow must be the only borrow",
                );
            }
        } else if (c.exclusiveOf(slot)) |_| {
            try c.diags.err(
                .borrow_conflict,
                expr.span,
                try c.diags.fmt("cannot borrow `{s}`", .{local.name}),
                "it is already borrowed mutably",
                "a mutable borrow must be the only borrow",
            );
        }

        try c.borrows.append(c.gpa, .{
            .slot = slot,
            .mutable = expr.mutable,
            .temporary = !c.persist_borrows,
            .span = expr.span,
        });
    }

    fn dropTemporaries(c: *Checker) void {
        var i: usize = 0;
        while (i < c.borrows.items.len) {
            if (c.borrows.items[i].temporary) {
                _ = c.borrows.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn tyName(c: *Checker, ty: types.Type) Error![]const u8 {
        return types.nameOf(c.diags.arena.allocator(), .{
            .structs = c.structs,
            .enums = c.enums,
        }, ty) catch error.OutOfMemory;
    }

    fn reportUseAfterMove(c: *Checker, slot: u32, span: Span) Error!void {
        const local = c.func.locals[slot];
        try c.diags.err(
            .use_after_move,
            span,
            try c.diags.fmt("use of moved value `{s}`", .{local.name}),
            "value used here after move",
            try c.diags.fmt(
                "`{s}` has type `{s}`, which is moved rather than copied",
                .{ local.name, try c.tyName(local.ty) },
            ),
        );
        c.states[slot] = .owned;
    }

    fn read(c: *Checker, expr: tir.Expr) Error!void {
        switch (expr) {
            .string_const, .int_const, .bool_const => {},

            .local_ref => |l| {
                if (c.states[l.slot] == .moved) try c.reportUseAfterMove(l.slot, l.span);
            },

            .field => |f| try c.read(f.base.*),

            .index => |x| {
                try c.read(x.base.*);
                try c.read(x.index.*);
            },

            .unary => |u| try c.read(u.operand.*),

            .binary => |b| {
                try c.read(b.lhs.*);
                try c.read(b.rhs.*);
            },

            .call_builtin => |call| for (call.args) |arg| try c.consume(arg),
            .call_function => |call| for (call.args) |arg| try c.consume(arg),
            .struct_lit => |lit| for (lit.fields) |value| try c.consume(value),
            .enum_lit => |lit| for (lit.payload) |value| try c.consume(value),
            .array_lit => |lit| for (lit.elems) |value| try c.consume(value),

            .if_expr => |node| try c.checkIf(node),
            .while_expr => |node| try c.checkWhile(node),
            .match => |m| try c.checkMatch(m),

            .deref => |d| try c.read(d.operand.*),
            .try_unwrap => |t| try c.consume(t.operand.*),
            .vec_op => |v| for (v.args) |arg| try c.read(arg),

            .borrow => |b| {
                try c.read(b.operand.*);
                try c.registerBorrow(b);
            },
        }
    }

    fn consume(c: *Checker, expr: tir.Expr) Error!void {
        switch (expr) {
            .local_ref => |l| {
                if (c.states[l.slot] == .moved) {
                    try c.reportUseAfterMove(l.slot, l.span);
                    return;
                }
                if (!types.isCopy(l.ty)) {
                    c.func.locals[l.slot].moved = true;
                    if (c.borrowOf(l.slot)) |b| {
                        const local = c.func.locals[l.slot];
                        try c.diags.err(
                            .move_while_borrowed,
                            l.span,
                            try c.diags.fmt("cannot move `{s}` while it is borrowed", .{local.name}),
                            "moved here",
                            "the borrow is still in scope",
                        );
                        _ = b;
                        return;
                    }
                    c.states[l.slot] = .moved;
                    c.moved_at[l.slot] = l.span;
                }
            },

            .field => |f| {
                if (types.isCopy(f.ty)) {
                    try c.read(f.base.*);
                } else {
                    try c.consume(f.base.*);
                }
            },

            .index => |x| {
                try c.read(x.index.*);
                if (types.isCopy(x.ty)) {
                    try c.read(x.base.*);
                } else {
                    try c.consume(x.base.*);
                }
            },

            else => try c.read(expr),
        }
    }

    fn snapshot(c: *Checker) Error![]State {
        return c.gpa.dupe(State, c.states);
    }

    fn mergeFrom(c: *Checker, other: []const State) void {
        for (c.states, other) |*state, incoming| {
            if (incoming == .moved) state.* = .moved;
        }
    }

    fn checkBlock(c: *Checker, block: tir.Block) Error!void {
        const mark = c.borrows.items.len;
        defer c.borrows.shrinkRetainingCapacity(mark);

        for (block.stmts) |stmt| {
            try c.checkStmt(stmt);
            c.dropTemporaries();
        }

        if (block.result) |r| {
            try c.consume(r.*);
            c.dropTemporaries();
        }
    }

    fn checkStmt(c: *Checker, stmt: tir.Stmt) Error!void {
        switch (stmt) {
            .expr => |e| try c.read(e),
            .assign => |a| {
                try c.consume(a.value);

                if (c.rootSlot(a.target)) |slot| {
                    if (c.borrowOf(slot)) |_| {
                        const local = c.func.locals[slot];
                        try c.diags.err(
                            .borrow_conflict,
                            a.span,
                            try c.diags.fmt("cannot assign to `{s}` while it is borrowed", .{local.name}),
                            "assigned here",
                            "the borrow is still in scope",
                        );
                    }
                }

                if (a.target == .local_ref) {
                    c.states[a.target.local_ref.slot] = .owned;
                    return;
                }

                try c.read(a.target);
            },
            .ret => |r| {
                if (r.value) |v| try c.consume(v);
            },
            .let => |l| {
                const saved = c.persist_borrows;
                c.persist_borrows = true;
                try c.consume(l.init);
                c.persist_borrows = saved;
                c.states[l.slot] = .owned;
            },
        }
    }

    fn checkIf(c: *Checker, node: tir.If) Error!void {
        try c.read(node.cond.*);

        const before = try c.snapshot();
        defer c.gpa.free(before);

        try c.checkBlock(node.then_block);

        const after_then = try c.snapshot();
        defer c.gpa.free(after_then);

        @memcpy(c.states, before);

        if (node.else_block) |b| try c.checkBlock(b);

        c.mergeFrom(after_then);
    }

    fn checkWhile(c: *Checker, node: tir.While) Error!void {
        try c.read(node.cond.*);

        const before = try c.snapshot();
        defer c.gpa.free(before);

        try c.checkBlock(node.body);

        for (c.states, before, 0..) |state, was, slot| {
            if (state == .moved and was == .owned) {
                const local = c.func.locals[slot];
                try c.diags.err(
                    .move_in_loop,
                    c.moved_at[slot],
                    try c.diags.fmt("`{s}` is moved inside a loop", .{local.name}),
                    "this runs more than once, so the value would move twice",
                    "move it before the loop, or make a fresh value each iteration",
                );
            }
        }

        @memcpy(c.states, before);
    }

    fn checkMatch(c: *Checker, m: tir.Match) Error!void {
        var moves_payload = false;
        for (m.arms) |arm| {
            for (arm.bindings) |slot| {
                if (!types.isCopy(c.func.locals[slot].ty)) moves_payload = true;
            }
        }

        if (moves_payload) {
            try c.consume(m.scrutinee.*);
        } else {
            try c.read(m.scrutinee.*);
        }

        const before = try c.snapshot();
        defer c.gpa.free(before);

        const merged = try c.snapshot();
        defer c.gpa.free(merged);

        for (m.arms) |arm| {
            @memcpy(c.states, before);
            for (arm.bindings) |slot| c.states[slot] = .owned;
            try c.read(arm.body);
            for (merged, c.states) |*state, now| {
                if (now == .moved) state.* = .moved;
            }
        }

        @memcpy(c.states, merged);
    }
};

pub fn check(
    gpa: std.mem.Allocator,
    program: tir.Program,
    diags: *diagnostics.Diagnostics,
) !void {
    for (program.functions) |func| {
        const states = try gpa.alloc(State, func.locals.len);
        defer gpa.free(states);
        const moved_at = try gpa.alloc(Span, func.locals.len);
        defer gpa.free(moved_at);

        @memset(states, .undeclared);
        @memset(moved_at, source.Span.zero);
        for (0..func.param_count) |i| states[i] = .owned;

        var borrows: std.ArrayList(ActiveBorrow) = .empty;
        defer borrows.deinit(gpa);

        var c: Checker = .{
            .gpa = gpa,
            .diags = diags,
            .structs = program.structs,
            .enums = program.enums,
            .program = program,
            .func = func,
            .states = states,
            .moved_at = moved_at,
            .borrows = borrows,
            .persist_borrows = false,
        };

        try c.checkBlock(func.body);
        borrows = c.borrows;
    }
}
