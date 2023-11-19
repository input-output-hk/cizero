const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    b.enable_wasmtime = true;

    const opts = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe }),
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

    {
        const exe = b.addExecutable(.{
            .name = "build-hook",
            .root_source_file = Build.LazyPath.relative("src/components/nix/build-hook/main.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });

        const install_exe = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "libexec/cizero/components/nix" } } });
        b.getInstallStep().dependOn(&install_exe.step);
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

    const test_pdk_step = b.step("test-pdk", "Run PDK tests");
    if (b.option([]const u8, "plugin", "Path to WASM module of a PDK test plugin")) |plugin_path| {
        const build_options = b.addOptions();
        build_options.addOption([]const u8, "plugin_path", plugin_path);

        const tests = b.addTest(.{
            .main_pkg_path = Build.LazyPath.relative("src"),
            .root_source_file = Build.LazyPath.relative("src/plugin/pdk-test.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        configureCompileStep(b, tests, opts);
        tests.addOptions("build_options", build_options);

        const run_tests = b.addRunArtifact(tests);
        test_pdk_step.dependOn(&run_tests.step);
    }
}

fn configureCompileStep(b: *Build, step: *Build.Step.Compile, dep_args: anytype) void {
    step.linkLibC();
    step.linkSystemLibrary("wasmtime");

    step.addModule("cron", b.dependency("cron", dep_args).module("cron"));
    step.addModule("datetime", b.dependency("datetime", dep_args).module("zig-datetime"));
    step.addModule("httpz", b.dependency("httpz", dep_args).module("httpz"));
    step.addModule("known-folders", b.dependency("known-folders", .{}).module("known-folders"));
}
