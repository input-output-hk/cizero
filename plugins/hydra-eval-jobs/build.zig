const std = @import("std");
const Build = std.Build;

const lib = @import("lib").lib;

pub fn build(b: *Build) !void {
    b.enable_wasmtime = true;

    const opts = .{
        .target = b.standardTargetOptions(.{ .default_target = .{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
        } }),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall }),
    };

    const source = b.path("main.zig");

    {
        const exe = b.addExecutable(.{
            .name = "hydra-eval-jobs",
            .root_source_file = source,
            .target = opts.target,
            .optimize = opts.optimize,
            .linkage = .dynamic,
        });
        configureCompileStep(b, exe, opts);

        const install_exe = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "libexec/cizero/plugins" } } });
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

    _ = lib.addCheckTls(b);
}

fn configureCompileStep(b: *Build, step: *Build.Step.Compile, opts: anytype) void {
    step.rdynamic = true;
    step.wasi_exec_model = .command;

    const pdk_mod = b.dependency("pdk", .{
        .target = opts.target,
        .release = opts.optimize != .Debug,
    }).module("cizero-pdk");

    step.root_module.addImport("cizero", pdk_mod);
    step.root_module.addImport("lib", pdk_mod.import_table.get("lib").?);
}
