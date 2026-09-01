pub const source = @import("source.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const token = @import("token.zig");
pub const lexer = @import("lexer.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const types = @import("types.zig");
pub const resolve = @import("resolve.zig");
pub const typecheck = @import("typecheck.zig");
pub const tir = @import("tir.zig");
pub const lower = @import("lower.zig");
pub const compile = @import("compile.zig");
pub const backend = struct {
    pub const zig = @import("backend/zig.zig");
    pub const runtime = @import("backend/runtime.zig");
};
