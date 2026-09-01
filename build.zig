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

    const update_goldens = b.option(bool, "update-goldens", "Rewrite golden files") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "update_goldens", update_goldens);

    const relastic_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cases_mod = b.createModule(.{
        .root_source_file = b.path("tests/run_cases.zig"),
        .target = target,
        .optimize = optimize,
    });
    cases_mod.addOptions("build_options", options);
    cases_mod.addImport("relastic", relastic_mod);

    const cases = b.addTest(.{ .root_module = cases_mod });
    const run_cases = b.addRunArtifact(cases);
    run_cases.setCwd(b.path("."));
    run_cases.has_side_effects = true;
    run_cases.step.dependOn(b.getInstallStep());
    b.step("cases", "Run compiler case tests").dependOn(&run_cases.step);
}
