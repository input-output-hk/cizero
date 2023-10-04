const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    b.enable_wasmtime = true;

    const opts = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };

    const source = Build.LazyPath.relative("src/main.zig");

    const run_step = b.step("run", "Run the app");
    {
        const exe = b.addExecutable(.{
            .name = "cizero",
            .root_source_file = source,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        configureCompileStep(b, exe, opts);
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
            .target = opts.target,
            .optimize = opts.optimize,
        });
        configureCompileStep(b, tests, opts);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}

fn configureCompileStep(b: *Build, step: *Build.Step.Compile, dep_args: anytype) void {
    step.linkLibC();
    step.linkSystemLibrary("wasmtime");

    step.addModule("cron", b.dependency("cron", dep_args).module("cron"));
    step.addModule("datetime", b.dependency("datetime", dep_args).module("zig-datetime"));
}
