const std = @import("std");

pub fn build(b: *std.Build) !void {
    b.enable_wasmtime = true;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const source = std.Build.LazyPath.relative("src/main.zig");

    const run_step = b.step("run", "Run the app");
    {
        const exe = b.addExecutable(.{
            .name = "cizero",
            .root_source_file = source,
            .target = target,
            .optimize = optimize,
        });
        configureCompileStep(exe);
        b.installArtifact(exe);

        const run_exe = b.addRunArtifact(exe);
        run_exe.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_exe.addArgs(args);
        run_step.dependOn(&run_exe.step);
    }

    const test_step = b.step("test", "Run unit tests");
    {
        const tests = b.addTest(.{
            .root_source_file = source,
            .target = target,
            .optimize = optimize,
        });
        configureCompileStep(tests);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}

fn configureCompileStep(step: *std.Build.Step.Compile) void {
    step.linkLibC();
    step.linkSystemLibrary("wasmtime");
}