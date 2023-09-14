const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const source = .{ .path = "src/main.zig" };

    {
        const exe = b.addExecutable(.{
            .name = "cizero",
            .root_source_file = source,
            .target = target,
            .optimize = optimize,
        });
        commonCompileStep(b, exe);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| run_cmd.addArgs(args);

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const unit_tests = b.addTest(.{
            .root_source_file = source,
            .target = target,
            .optimize = optimize,
        });
        commonCompileStep(b, unit_tests);

        const run_unit_tests = b.addRunArtifact(unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }
}

fn commonCompileStep(b: *std.Build, step: *std.Build.Step.Compile) void {
    step.addModule("tres", b.dependency("tres", .{}).module("tres"));

    step.linkLibC();
    step.linkSystemLibrary("wasmedge");

    step.addIncludePath(.{ .path = "src/c" });
    step.addCSourceFile(.{
        .file = .{ .path = "src/c/util.c" },
        .flags = &.{},
    });
}
