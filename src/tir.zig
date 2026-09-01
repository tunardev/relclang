const source = @import("source.zig");
const types = @import("types.zig");

const Span = source.Span;

pub const Builtin = enum {
    print_line,
};

pub const StringConst = struct {
    value: []const u8,
    ty: types.Type,
    span: Span,
};

pub const CallBuiltin = struct {
    builtin: Builtin,
    args: []const Expr,
    ty: types.Type,
    span: Span,
};

pub const CallFunction = struct {
    target: usize,
    args: []const Expr,
    ty: types.Type,
    span: Span,
};

pub const Expr = union(enum) {
    string_const: StringConst,
    call_builtin: CallBuiltin,
    call_function: CallFunction,

    pub fn typeOf(e: Expr) types.Type {
        return switch (e) {
            .string_const => |s| s.ty,
            .call_builtin => |c| c.ty,
            .call_function => |c| c.ty,
        };
    }

    pub fn spanOf(e: Expr) Span {
        return switch (e) {
            .string_const => |s| s.span,
            .call_builtin => |c| c.span,
            .call_function => |c| c.span,
        };
    }
};

pub const Stmt = union(enum) {
    expr: Expr,
};

pub const Block = struct {
    stmts: []const Stmt,
};

pub const Function = struct {
    name: []const u8,
    is_entry: bool,
    body: Block,
    span: Span,
};

pub const Program = struct {
    functions: []const Function,
};
