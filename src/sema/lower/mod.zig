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

const context = @import("context.zig");
const Error = context.Error;
const Fn = context.Fn;
const mono_mod = @import("mono.zig");
const Mono = mono_mod.Mono;
const block_mod = @import("block.zig");
const lowerBlock = block_mod.lowerBlock;

pub fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    program: ast.Program,
    symbols: *resolve.SymbolTable,
    diags: *diagnostics.Diagnostics,
) Error!tir.Program {
    const ast_to_tir = try arena.alloc(?usize, symbols.all_fns.len);
    @memset(ast_to_tir, null);

    var mono: Mono = .{
        .arena = arena,
        .gpa = gpa,
        .symbols = symbols,
        .diags = diags,
        .program = program,
        .functions = .empty,
        .ast_to_tir = ast_to_tir,
        .instances = .empty,
        .pending = .empty,
    };
    defer mono.instances.deinit(gpa);
    defer mono.pending.deinit(gpa);

    for (symbols.all_fns, 0..) |_, index| {
        if (symbols.signature(index).isGeneric()) continue;
        ast_to_tir[index] = mono.functions.items.len;
        try mono.functions.append(arena, undefined);
    }

    for (symbols.all_fns, 0..) |_, index| {
        if (ast_to_tir[index]) |tir_index| {
            const lowered = try lowerFunction(&mono, index, &.{}, tir_index);
            mono.functions.items[tir_index] = lowered;
        }
    }

    while (mono.pending.pop()) |job| {
        const lowered = try lowerFunction(&mono, job.ast_index, job.args, job.tir_index);
        mono.functions.items[job.tir_index] = lowered;
    }

    return .{
        .functions = try mono.functions.toOwnedSlice(arena),
        .structs = symbols.structs.items,
        .enums = symbols.enums.items,
    };
}

pub fn lowerFunction(
    mono: *Mono,
    index: usize,
    type_args: []const Type,
    tir_index: usize,
) Error!tir.Function {
    const arena = mono.arena;
    const gpa = mono.gpa;
    const symbols = mono.symbols;
    const diags = mono.diags;
    _ = tir_index;

    {
        const f = symbols.all_fns[index];
        var ctx: Fn = .{
            .arena = arena,
            .gpa = gpa,
            .symbols = symbols,
            .diags = diags,
            .mono = mono,
            .name = f.name,
            .ret_ty = .void,
            .param_count = 0,
            .type_args = type_args,
            .expected = null,
            .temps = .empty,
            .bindings = .empty,
            .locals = .empty,
            .depth = 0,
        };
        defer ctx.deinit();

        const raw = symbols.signature(index);
        const info: resolve.FnInfo = .{
            .name = raw.name,
            .params = blk: {
                const out = try arena.alloc(Type, raw.params.len);
                for (raw.params, 0..) |p, i| out[i] = try types.substitute(arena, p, type_args);
                break :blk out;
            },
            .ret = try types.substitute(arena, raw.ret, type_args),
            .type_param_count = 0,
        };

        var slot_offset: usize = 0;
        if (f.has_self) {
            _ = try ctx.declareMut("self", info.params[0], false);
            slot_offset = 1;
        }

        for (f.params, 0..) |param, i| {
            if (ctx.declaredAtDepth(param.name)) {
                try diags.err(
                    .duplicate_binding,
                    param.name_span,
                    try diags.fmt("`{s}` is already a parameter", .{param.name}),
                    "duplicate parameter",
                    null,
                );
            }
            _ = try ctx.declareMut(param.name, info.params[i + slot_offset], false);
        }

        const param_count: u32 = @intCast(f.params.len + slot_offset);
        ctx.param_count = param_count;
        ctx.ret_ty = info.ret;
        ctx.expected = if (info.ret == .void) null else info.ret;

        const body = try lowerBlock(&ctx, f.body, info.ret != .void);

        if (body.result) |result| try ctx.checkEscape(result.*, f.name);

        if (info.ret != .void and !body.diverges()) {
            if (body.result) |result| {
                const ty = result.typeOf();
                if (!ty.isInvalid() and !Type.eql(ty, info.ret)) {
                    try diags.err(
                        .missing_return,
                        result.spanOf(),
                        "the final expression does not match the return type",
                        try diags.fmt("expected `{s}`, found `{s}`", .{
                            try symbols.typeName(diags.arena.allocator(), info.ret),
                            try symbols.typeName(diags.arena.allocator(), ty),
                        }),
                        null,
                    );
                }
            } else {
                try diags.err(
                    .missing_return,
                    if (f.ret_ty) |t| t.spanOf() else f.name_span,
                    try diags.fmt("`{s}` must end with a `{s}` value", .{
                        f.name,
                        try symbols.typeName(diags.arena.allocator(), info.ret),
                    }),
                    "no value is returned",
                    "the last line of the body is its return value",
                );
            }
        }

        return .{
            .name = try instanceName(arena, f.name, type_args, symbols),
            .is_entry = symbols.entry != null and symbols.entry.? == index,
            .param_count = param_count,
            .ret = info.ret,
            .locals = try ctx.locals.toOwnedSlice(arena),
            .body = body,
            .span = f.span,
        };
    }
}

pub fn instanceName(
    arena: std.mem.Allocator,
    name: []const u8,
    args: []const Type,
    symbols: *resolve.SymbolTable,
) Error![]const u8 {
    if (args.len == 0) return name;

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, name);
    for (args) |arg| {
        try out.append(arena, '_');
        const text = symbols.typeName(arena, arg) catch return error.OutOfMemory;
        for (text) |ch| {
            try out.append(arena, switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9' => ch,
                else => '_',
            });
        }
    }
    return out.toOwnedSlice(arena);
}
