const std = @import("std");
const source = @import("../source.zig");

const Span = source.Span;

pub const Code = enum {
    unexpected_token,
    unterminated_string,
    unknown_escape,
    unknown_function,
    missing_main,
    duplicate_function,
    wrong_arg_count,
    type_mismatch,
    unexpected_char,
    invalid_number,
    duplicate_binding,
    unknown_variable,
    invalid_operand,
    integer_overflow,
    unused_value,
    missing_return,
    bad_signature,
    unknown_struct,
    unknown_field,
    missing_field,
    recursive_struct,
    not_indexable,
    non_exhaustive,
    unreachable_arm,
    bad_pattern,
    not_assignable,
    immutable_assign,
    use_after_move,
    move_in_loop,
    borrow_conflict,
    move_while_borrowed,
    cannot_infer,
    unknown_trait,
    unknown_method,
    missing_impl,

    pub fn id(c: Code) []const u8 {
        return switch (c) {
            .unexpected_token => "E0001",
            .unterminated_string => "E0002",
            .unknown_escape => "E0003",
            .unknown_function => "E0004",
            .missing_main => "E0005",
            .duplicate_function => "E0006",
            .wrong_arg_count => "E0007",
            .type_mismatch => "E0008",
            .unexpected_char => "E0009",
            .invalid_number => "E0010",
            .duplicate_binding => "E0011",
            .unknown_variable => "E0012",
            .invalid_operand => "E0013",
            .integer_overflow => "E0014",
            .unused_value => "E0015",
            .missing_return => "E0016",
            .bad_signature => "E0017",
            .unknown_struct => "E0018",
            .unknown_field => "E0019",
            .missing_field => "E0020",
            .recursive_struct => "E0021",
            .not_indexable => "E0022",
            .non_exhaustive => "E0023",
            .unreachable_arm => "E0024",
            .bad_pattern => "E0025",
            .not_assignable => "E0026",
            .immutable_assign => "E0027",
            .use_after_move => "E0028",
            .move_in_loop => "E0029",
            .borrow_conflict => "E0030",
            .move_while_borrowed => "E0031",
            .cannot_infer => "E0032",
            .unknown_trait => "E0033",
            .unknown_method => "E0034",
            .missing_impl => "E0035",
        };
    }
};

pub const Severity = enum {
    err,
    warning,
    note,

    pub fn text(s: Severity) []const u8 {
        return switch (s) {
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }
};

pub const Diagnostic = struct {
    severity: Severity,
    code: ?Code,
    message: []const u8,
    span: ?Span,
    label: ?[]const u8,
    help: ?[]const u8,
};
