const source = @import("source.zig");

pub const Kind = enum {
    kw_fn,
    kw_let,
    ident,
    int,
    string,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    comma,
    colon,
    equals,
    plus,
    minus,
    star,
    slash,
    percent,
    arrow,
    newline,
    eof,
    invalid,

    pub fn describe(k: Kind) []const u8 {
        return switch (k) {
            .kw_fn => "`fn`",
            .kw_let => "`let`",
            .ident => "an identifier",
            .int => "an integer literal",
            .string => "a string literal",
            .l_paren => "`(`",
            .r_paren => "`)`",
            .l_brace => "`{`",
            .r_brace => "`}`",
            .comma => "`,`",
            .colon => "`:`",
            .equals => "`=`",
            .plus => "`+`",
            .minus => "`-`",
            .star => "`*`",
            .slash => "`/`",
            .percent => "`%`",
            .arrow => "`->`",
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
