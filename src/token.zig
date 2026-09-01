const source = @import("source.zig");

pub const Kind = enum {
    kw_fn,
    ident,
    string,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    comma,
    newline,
    eof,
    invalid,

    pub fn describe(k: Kind) []const u8 {
        return switch (k) {
            .kw_fn => "`fn`",
            .ident => "an identifier",
            .string => "a string literal",
            .l_paren => "`(`",
            .r_paren => "`)`",
            .l_brace => "`{`",
            .r_brace => "`}`",
            .comma => "`,`",
            .newline => "a line break",
            .eof => "end of file",
            .invalid => "an invalid token",
        };
    }
};

pub const Token = struct {
    kind: Kind,
    span: source.Span,
    value: []const u8 = &.{},
};
