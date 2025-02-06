const std = @import("std");
const Build = std.Build;

const utils = @import("utils").utils;

pub fn build(b: *Build) !void {
    b.enable_wasmtime = true;

    const opts = .{
        .target = b.standardTargetOptions(.{ .default_target = .{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
        } }),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall }),
    };

    const exe = b.addExecutable(.{
        .name = "hydra-eval-jobs",
        .root_source_file = b.path("main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .linkage = .dynamic,
    });
    configureCompileStep(exe);
    {
        const pdk_mod = b.dependency("pdk", .{
            .target = opts.target,
            .release = opts.optimize != .Debug,
        }).module("cizero-pdk");

        exe.root_module.addImport("cizero", pdk_mod);
        // Getting from `import_table` as a workaround for "file exists in multiple modules" error.
        exe.root_module.addImport("utils", pdk_mod.import_table.get("utils").?);
    }
    exe.root_module.addImport("s2s", b.dependency("s2s", opts).module("s2s"));

    {
        const install_exe = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "libexec/cizero/plugins" } } });
        b.getInstallStep().dependOn(&install_exe.step);
    }

    const test_step = b.step("test", "Run unit tests");
    {
        const tests = utils.addModuleTest(b, &exe.root_module, .{});
        configureCompileStep(tests);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    _ = utils.addCheckTls(b);
}

fn configureCompileStep(step: *Build.Step.Compile) void {
    step.rdynamic = true;
    step.wasi_exec_model = .command;
}
