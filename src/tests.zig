test {
    _ = @import("cli.zig");
    _ = @import("source.zig");
    _ = @import("diagnostics.zig");
    _ = @import("token.zig");
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
    _ = @import("parser.zig");
    _ = @import("types.zig");
    _ = @import("resolve.zig");
    _ = @import("typecheck.zig");
    _ = @import("tir.zig");
    _ = @import("lower.zig");
    _ = @import("backend/runtime.zig");
    _ = @import("backend/zig.zig");
    _ = @import("compile.zig");
}
