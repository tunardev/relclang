pub const Type = enum {
    void,
    str,
    invalid,

    pub fn name(t: Type) []const u8 {
        return switch (t) {
            .void => "Void",
            .str => "Str",
            .invalid => "<invalid>",
        };
    }
};
