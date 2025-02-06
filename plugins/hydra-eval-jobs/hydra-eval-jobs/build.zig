const std = @import("std");

const utils = @import("utils").utils;

pub fn build(b: *std.Build) void {
    const opts = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe }),
    };

    const exe = b.addExecutable(.{
        .name = "hydra-eval-jobs",
        .root_source_file = b.path("main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    exe.root_module.addImport("utils", b.dependency("utils", opts).module("utils"));
    exe.root_module.addImport("args", b.dependency("args", opts).module("args"));
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    {
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);

        run_step.dependOn(&run_cmd.step);
    }

    const test_step = b.step("test", "Run unit tests");
    {
        const exe_test = utils.addModuleTest(b, &exe.root_module, .{});

        const run_exe_test = b.addRunArtifact(exe_test);
        test_step.dependOn(&run_exe_test.step);
    }

    _ = utils.addCheckTls(b);
}
