pub const support = struct {
    pub const source = @import("support/source.zig");
    pub const diagnostics = @import("support/diagnostics.zig");
};

pub const syntax = struct {
    pub const token = @import("syntax/token.zig");
    pub const lexer = @import("syntax/lexer.zig");
    pub const ast = @import("syntax/ast.zig");
    pub const parser = @import("syntax/parser.zig");
};

pub const sema = struct {
    pub const types = @import("sema/types.zig");
    pub const type_rules = @import("sema/type_rules.zig");
    pub const symbols = @import("sema/symbols.zig");
    pub const resolve = @import("sema/resolve.zig");
    pub const lower = @import("sema/lower.zig");
    pub const ownership = @import("sema/ownership.zig");
};

pub const ir = struct {
    pub const tir = @import("ir/tir.zig");
};

pub const backend = struct {
    pub const zig = @import("backend/zig_backend.zig");
    pub const runtime = @import("backend/runtime.zig");
};

pub const driver = struct {
    pub const pipeline = @import("driver/pipeline.zig");
    pub const cli = @import("driver/cli.zig");
};

pub const source = support.source;
pub const diagnostics = support.diagnostics;
pub const compile = driver.pipeline;
