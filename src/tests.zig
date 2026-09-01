test {
    _ = @import("support/source.zig");
    _ = @import("support/diag/model.zig");
    _ = @import("support/diag/render.zig");
    _ = @import("support/diagnostics.zig");
    _ = @import("support/diagnostics_test.zig");

    _ = @import("syntax/token.zig");
    _ = @import("syntax/lexer.zig");
    _ = @import("syntax/lexer_test.zig");
    _ = @import("syntax/ast.zig");
    _ = @import("syntax/parser.zig");
    _ = @import("syntax/parser_test.zig");

    _ = @import("sema/types.zig");
    _ = @import("sema/types_test.zig");
    _ = @import("sema/type_rules.zig");
    _ = @import("sema/type_rules_test.zig");
    _ = @import("sema/symbols.zig");
    _ = @import("sema/resolve.zig");
    _ = @import("sema/resolve_test.zig");
    _ = @import("sema/lower.zig");
    _ = @import("sema/lower_test.zig");
    _ = @import("sema/ownership.zig");
    _ = @import("sema/ownership_test.zig");

    _ = @import("ir/tir.zig");

    _ = @import("backend/runtime.zig");
    _ = @import("backend/zig_backend.zig");
    _ = @import("backend/zig_backend_test.zig");

    _ = @import("driver/cli.zig");
    _ = @import("driver/pipeline.zig");
    _ = @import("driver/pipeline_test.zig");
}
