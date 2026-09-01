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

    pub fn symbol(o: BinOp) []const u8 {
        return switch (o) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .rem => "%",
        };
    }
};

pub const UnOp = enum {
    neg,

    pub fn symbol(o: UnOp) []const u8 {
        return switch (o) {
            .neg => "-",
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
    var_ref: VarRef,
    call: Call,
    binary: Binary,
    unary: Unary,

    pub fn spanOf(e: Expr) Span {
        return switch (e) {
            .string => |s| s.span,
            .int => |i| i.span,
            .var_ref => |v| v.span,
            .call => |c| c.span,
            .binary => |b| b.span,
            .unary => |u| u.span,
        };
    }
};

pub const Let = struct {
    name: []const u8,
    name_span: Span,
    ty_name: ?[]const u8,
    ty_span: ?Span,
    init: Expr,
    span: Span,
};

pub const Stmt = union(enum) {
    expr: Expr,
    let: Let,

    pub fn spanOf(s: Stmt) Span {
        return switch (s) {
            .expr => |e| e.spanOf(),
            .let => |l| l.span,
        };
    }
};

pub const Block = struct {
    stmts: []const Stmt,
    span: Span,
};

pub const Fn = struct {
    name: []const u8,
    name_span: Span,
    body: Block,
    span: Span,
};

pub const Program = struct {
    fns: []const Fn,
};
