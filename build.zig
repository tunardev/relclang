const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "relc", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_step = b.addRunArtifact(exe);
    run_step.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_step.addArgs(args);
    b.step("run", "Run relc").dependOn(&run_step.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(unit_tests).step);
}
