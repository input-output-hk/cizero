const std = @import("std");

pub fn build(b: *std.Build) !void {
    b.enable_wasmtime = true;

    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    } });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const source = std.Build.LazyPath.relative("main.zig");

    {
        const exe = b.addExecutable(.{
            .name = "foo",
            .root_source_file = source,
            .target = target,
            .optimize = optimize,
            .linkage = .dynamic,
        });
        configureCompileStep(exe);

        const install_exe = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "libexec/cizero/plugins" } } });
        b.getInstallStep().dependOn(&install_exe.step);
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
    step.rdynamic = true;
    step.wasi_exec_model = .command;

    step.addAnonymousModule("cizero", .{ .source_file = std.Build.LazyPath.relative("../../pdk/zig/main.zig") });
}
