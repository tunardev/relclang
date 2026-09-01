const source = @import("source.zig");
const types = @import("types.zig");

const Span = source.Span;

pub const Builtin = enum {
    print_line,
};

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
};

pub const UnOp = enum {
    neg,
};

pub const StringConst = struct {
    value: []const u8,
    ty: types.Type,
    span: Span,
};

pub const IntConst = struct {
    value: i64,
    ty: types.Type,
    span: Span,
};

pub const LocalRef = struct {
    slot: u32,
    ty: types.Type,
    span: Span,
};

pub const Binary = struct {
    op: BinOp,
    lhs: *const Expr,
    rhs: *const Expr,
    ty: types.Type,
    span: Span,
};

pub const Unary = struct {
    op: UnOp,
    operand: *const Expr,
    ty: types.Type,
    span: Span,
};

pub const CallBuiltin = struct {
    builtin: Builtin,
    args: []const Expr,
    ty: types.Type,
    span: Span,
};

pub const StructLit = struct {
    strukt: u32,
    fields: []const Expr,
    ty: types.Type,
    span: Span,
};

pub const FieldAccess = struct {
    base: *const Expr,
    strukt: u32,
    field: u32,
    ty: types.Type,
    span: Span,
};

pub const ArrayLit = struct {
    elems: []const Expr,
    ty: types.Type,
    span: Span,
};

pub const Index = struct {
    base: *const Expr,
    index: *const Expr,
    ty: types.Type,
    span: Span,
};

pub const EnumLit = struct {
    enumeration: u32,
    variant: u32,
    payload: []const Expr,
    ty: types.Type,
    span: Span,
};

pub const MatchArm = struct {
    variant: ?u32,
    bindings: []const u32,
    body: Expr,
    span: Span,
};

pub const Match = struct {
    scrutinee: *const Expr,
    enumeration: u32,
    arms: []const MatchArm,
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
    int_const: IntConst,
    local_ref: LocalRef,
    binary: Binary,
    unary: Unary,
    call_builtin: CallBuiltin,
    call_function: CallFunction,
    struct_lit: StructLit,
    field: FieldAccess,
    array_lit: ArrayLit,
    index: Index,
    enum_lit: EnumLit,
    match: Match,

    pub fn typeOf(e: Expr) types.Type {
        return switch (e) {
            .string_const => |s| s.ty,
            .int_const => |i| i.ty,
            .local_ref => |l| l.ty,
            .binary => |b| b.ty,
            .unary => |u| u.ty,
            .call_builtin => |c| c.ty,
            .call_function => |c| c.ty,
            .struct_lit => |s| s.ty,
            .field => |f| f.ty,
            .array_lit => |a| a.ty,
            .index => |x| x.ty,
            .enum_lit => |lit| lit.ty,
            .match => |m| m.ty,
        };
    }

    pub fn spanOf(e: Expr) Span {
        return switch (e) {
            .string_const => |s| s.span,
            .int_const => |i| i.span,
            .local_ref => |l| l.span,
            .binary => |b| b.span,
            .unary => |u| u.span,
            .call_builtin => |c| c.span,
            .call_function => |c| c.span,
            .struct_lit => |s| s.span,
            .field => |f| f.span,
            .array_lit => |a| a.span,
            .index => |x| x.span,
            .enum_lit => |lit| lit.span,
            .match => |m| m.span,
        };
    }
};

pub const LetDecl = struct {
    slot: u32,
    init: Expr,
    ty: types.Type,
    span: Span,
};

pub const Stmt = union(enum) {
    expr: Expr,
    let: LetDecl,
    ret_value: Expr,
};

pub const Local = struct {
    name: []const u8,
    ty: types.Type,
    used: bool,
};

pub const Block = struct {
    stmts: []const Stmt,
};

pub const Function = struct {
    name: []const u8,
    is_entry: bool,
    param_count: u32,
    ret: types.Type,
    locals: []const Local,
    body: Block,
    span: Span,
};

pub const Program = struct {
    functions: []const Function,
    structs: []const types.StructDef,
    enums: []const types.EnumDef,
};
