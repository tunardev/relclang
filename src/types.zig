pub const Type = enum {
    void,
    int,
    str,
    invalid,

    pub fn name(t: Type) []const u8 {
        return switch (t) {
            .void => "Void",
            .int => "Int",
            .str => "Str",
            .invalid => "<invalid>",
        };
    }
};
