const std = @import("std");
const source = @import("source.zig");
const diagnostics = @import("diagnostics.zig");
const tir = @import("tir.zig");
const types = @import("types.zig");

const Span = source.Span;

const Error = error{OutOfMemory};

const State = enum {
    undeclared,
    owned,
    moved,
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
        for (block.stmts) |stmt| try c.checkStmt(stmt);
        if (block.result) |r| try c.consume(r.*);
    }

    fn checkStmt(c: *Checker, stmt: tir.Stmt) Error!void {
        switch (stmt) {
            .expr => |e| try c.read(e),
            .assign => |a| {
                try c.consume(a.value);

                if (a.target == .local_ref) {
                    c.states[a.target.local_ref.slot] = .owned;
                    return;
                }

                try c.read(a.target);
            },
            .let => |l| {
                try c.consume(l.init);
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

        var c: Checker = .{
            .gpa = gpa,
            .diags = diags,
            .structs = program.structs,
            .enums = program.enums,
            .program = program,
            .func = func,
            .states = states,
            .moved_at = moved_at,
        };

        try c.checkBlock(func.body);
    }
}
