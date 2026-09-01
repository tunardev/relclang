const std = @import("std");
const rt = @import("relastic_rt.zig");

const E0_Result_Int_Str = union(enum) {
    v0_Ok: struct { f0: i64 },
    v1_Err: struct { f0: []const u8 },
};

const S0_Point = struct {
    f0_x: i64,
    f1_y: i64,
};

fn rc_magnitude2(v0_p: *const S0_Point) rt.Error!i64 {
    return (((v0_p).*.f0_x * (v0_p).*.f0_x) + ((v0_p).*.f1_y * (v0_p).*.f1_y));
}

fn rc_checked(v0_p: *const S0_Point) rt.Error!E0_Result_Int_Str {
    return if ((((v0_p).*.f0_x == @as(i64, 0)) and ((v0_p).*.f1_y == @as(i64, 0)))) b0: {
            break :b0 E0_Result_Int_Str{ .v1_Err = .{ .f0 = "origin has no direction" } };
    } else b1: {
            break :b1 E0_Result_Int_Str{ .v0_Ok = .{ .f0 = (try rc_magnitude2(v0_p)) } };
    };
}

fn rc_doubled(v0_p: *const S0_Point) rt.Error!E0_Result_Int_Str {
    const v1_m = b0: {
            switch ((try rc_checked(v0_p))) {
                .v0_Ok => |__t| break :b0 __t.f0,
                .v1_Err => |__e| return E0_Result_Int_Str{ .v1_Err = __e },
            }
    };
    return E0_Result_Int_Str{ .v0_Ok = .{ .f0 = (v1_m * @as(i64, 2)) } };
}

fn rc_report(v0_p: *const S0_Point) rt.Error!i64 {
    return switch ((try rc_doubled(v0_p))) {
        .v0_Ok => |__p| blk: {
            const v1_v = __p.f0;
            break :blk v1_v;
        },
        .v1_Err => |__p| blk: {
            const v2_e = __p.f0;
            _ = v2_e;
            break :blk @as(i64, 0);
        },
    };
}

fn rc_main() rt.Error!void {
    const v0_p = S0_Point{ .f0_x = @as(i64, 3), .f1_y = @as(i64, 4) };
    const v1_origin = S0_Point{ .f0_x = @as(i64, 0), .f1_y = @as(i64, 0) };
    (try rt.printLine((try rc_describe_Point(&(v0_p)))));
    (try rt.printLineInt((try rc_magnitude2(&(v0_p)))));
    (try rt.printLineInt((try rc_report(&(v0_p)))));
    (try rt.printLineInt((try rc_report(&(v1_origin)))));
}

fn rc_Point_show(v0_self: *const S0_Point) rt.Error![]const u8 {
    _ = v0_self;
    return "a point";
}

fn rc_describe_Point(v0_value: *const S0_Point) rt.Error![]const u8 {
    return (try rc_Point_show(v0_value));
}

pub fn main(init: std.process.Init) !void {
    rt.init(init.io);
    try rc_main();
}
