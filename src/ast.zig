const source = @import("source.zig");

const Span = source.Span;

pub const Str = struct {
    value: []const u8,
    span: Span,
};

pub const IntLit = struct {
    text: []const u8,
    span: Span,
};

pub const BoolLit = struct {
    value: bool,
    span: Span,
};

pub const VarRef = struct {
    name: []const u8,
    span: Span,
};

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    logical_and,
    logical_or,

    pub fn symbol(o: BinOp) []const u8 {
        return switch (o) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .rem => "%",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .gt => ">",
            .le => "<=",
            .ge => ">=",
            .logical_and => "and",
            .logical_or => "or",
        };
    }
};

pub const UnOp = enum {
    neg,
    not,

    pub fn symbol(o: UnOp) []const u8 {
        return switch (o) {
            .neg => "-",
            .not => "not",
        };
    }
};

pub const Binary = struct {
    op: BinOp,
    lhs: *const Expr,
    rhs: *const Expr,
    op_span: Span,
    span: Span,
};

pub const Unary = struct {
    op: UnOp,
    operand: *const Expr,
    op_span: Span,
    span: Span,
};

pub const Call = struct {
    callee: []const u8,
    callee_span: Span,
    args: []const Expr,
    span: Span,
};

pub const Expr = union(enum) {
    string: Str,
    int: IntLit,
    boolean: BoolLit,
    var_ref: VarRef,
    call: Call,
    binary: Binary,
    unary: Unary,
    struct_lit: StructLit,
    field: FieldAccess,
    array_lit: ArrayLit,
    index: Index,
    match: Match,
    if_expr: If,
    while_expr: While,
    borrow: Borrow,

    pub fn spanOf(e: Expr) Span {
        return switch (e) {
            .string => |s| s.span,
            .int => |i| i.span,
            .boolean => |b| b.span,
            .var_ref => |v| v.span,
            .call => |c| c.span,
            .binary => |b| b.span,
            .unary => |u| u.span,
            .struct_lit => |s| s.span,
            .field => |f| f.span,
            .array_lit => |a| a.span,
            .index => |x| x.span,
            .match => |m| m.span,
            .if_expr => |i| i.span,
            .while_expr => |x| x.span,
            .borrow => |b| b.span,
        };
    }
};

pub const Let = struct {
    name: []const u8,
    name_span: Span,
    is_mut: bool,
    ty: ?TypeExpr,
    init: Expr,
    span: Span,
};

pub const Assign = struct {
    target: Expr,
    value: Expr,
    span: Span,
};

pub const Stmt = union(enum) {
    expr: Expr,
    let: Let,
    assign: Assign,

    pub fn spanOf(s: Stmt) Span {
        return switch (s) {
            .expr => |e| e.spanOf(),
            .let => |l| l.span,
            .assign => |a| a.span,
        };
    }
};

pub const Block = struct {
    stmts: []const Stmt,
    span: Span,
};

pub const TypeParam = struct {
    name: []const u8,
    span: Span,
};

pub const TypeExpr = union(enum) {
    named: struct { name: []const u8, args: []const TypeExpr, span: Span },
    array: struct { elem: *const TypeExpr, len_text: []const u8, len_span: Span, span: Span },
    ref: struct { mutable: bool, target: *const TypeExpr, span: Span },

    pub fn spanOf(t: TypeExpr) Span {
        return switch (t) {
            .named => |n| n.span,
            .array => |a| a.span,
            .ref => |r| r.span,
        };
    }
};

pub const Borrow = struct {
    mutable: bool,
    operand: *const Expr,
    span: Span,
};

pub const FieldDecl = struct {
    name: []const u8,
    name_span: Span,
    ty: TypeExpr,
};

pub const StructDecl = struct {
    name: []const u8,
    name_span: Span,
    type_params: []const TypeParam,
    fields: []const FieldDecl,
    span: Span,
};

pub const VariantDecl = struct {
    name: []const u8,
    name_span: Span,
    payload: []const TypeExpr,
};

pub const EnumDecl = struct {
    name: []const u8,
    name_span: Span,
    type_params: []const TypeParam,
    variants: []const VariantDecl,
    span: Span,
};

pub const Binding = struct {
    name: []const u8,
    span: Span,
};

pub const Pattern = union(enum) {
    wildcard: Span,
    variant: struct {
        name: []const u8,
        name_span: Span,
        bindings: []const Binding,
        has_parens: bool,
        span: Span,
    },

    pub fn spanOf(p: Pattern) Span {
        return switch (p) {
            .wildcard => |s| s,
            .variant => |v| v.span,
        };
    }
};

pub const Arm = struct {
    pattern: Pattern,
    body: Expr,
    span: Span,
};

pub const Match = struct {
    scrutinee: *const Expr,
    arms: []const Arm,
    span: Span,
};

pub const If = struct {
    cond: *const Expr,
    then_block: Block,
    else_block: ?Block,
    else_if: ?*const Expr,
    span: Span,
};

pub const While = struct {
    cond: *const Expr,
    body: Block,
    span: Span,
};

pub const FieldInit = struct {
    name: []const u8,
    name_span: Span,
    value: Expr,
};

pub const StructLit = struct {
    name: []const u8,
    name_span: Span,
    fields: []const FieldInit,
    span: Span,
};

pub const FieldAccess = struct {
    base: *const Expr,
    field: []const u8,
    field_span: Span,
    span: Span,
};

pub const ArrayLit = struct {
    elems: []const Expr,
    span: Span,
};

pub const Index = struct {
    base: *const Expr,
    index: *const Expr,
    span: Span,
};

pub const Param = struct {
    name: []const u8,
    name_span: Span,
    ty: TypeExpr,
};

pub const Fn = struct {
    name: []const u8,
    name_span: Span,
    type_params: []const TypeParam,
    params: []const Param,
    ret_ty: ?TypeExpr,
    body: Block,
    span: Span,
};

pub const Program = struct {
    fns: []const Fn,
    structs: []const StructDecl,
    enums: []const EnumDecl,
};
