const std = @import("std");
const cli = @import("driver/cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    return cli.run(arena, init.gpa, init.io, argv);
}
