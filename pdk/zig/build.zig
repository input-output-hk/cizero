const std = @import("std");

pub fn build(b: *std.Build) !void {
    b.enable_wasmtime = true;

    const opts = .{
        .target = b.standardTargetOptions(.{ .default_target = .{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
        } }),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall }),
    };

    const module = b.addModule("cizero-pdk", .{ .root_source_file = std.Build.LazyPath.relative("main.zig") });
    configureModule(b, module, opts);

    const test_step = b.step("test", "Run unit tests");
    {
        const tests = b.addTest(.{
            .root_source_file = module.root_source_file.?,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        configureCompileStep(b, tests, opts);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}

fn configureCompileStep(b: *std.Build, step: *std.Build.Step.Compile, opts: anytype) void {
    step.rdynamic = true;
    step.wasi_exec_model = .command;

    configureModule(b, &step.root_module, opts);
}

fn configureModule(b: *std.Build, module: *std.Build.Module, opts: anytype) void {
    module.addImport("trait", b.dependency("trait", .{
        .target = opts.target,
        .optimize = opts.optimize,
    }).module("zigtrait"));
}
