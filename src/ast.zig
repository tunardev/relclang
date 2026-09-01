const source = @import("source.zig");

const Span = source.Span;

pub const Str = struct {
    value: []const u8,
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
    call: Call,

    pub fn spanOf(e: Expr) Span {
        return switch (e) {
            .string => |s| s.span,
            .call => |c| c.span,
        };
    }
};

pub const Stmt = union(enum) {
    expr: Expr,

    pub fn spanOf(s: Stmt) Span {
        return switch (s) {
            .expr => |e| e.spanOf(),
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
