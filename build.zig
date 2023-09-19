const std = @import("std");

pub fn build(b: *std.Build) !void {
    b.enable_wasmtime = true;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const source = std.Build.LazyPath.relative("src/main.zig");

    {
        const exe = b.addExecutable(.{
            .name = "cizero",
            .root_source_file = source,
            .target = target,
            .optimize = optimize,
        });
        configureCompileStep(exe);

        b.installArtifact(exe);

        {
            const run_cmd = b.addRunArtifact(exe);

            run_cmd.step.dependOn(b.getInstallStep());

            if (b.args) |args| run_cmd.addArgs(args);

            const run_step = b.step("run", "Run the app");
            run_step.dependOn(&run_cmd.step);
        }
    }

    const test_step = blk: {
        const unit_tests = b.addTest(.{
            .root_source_file = source,
            .target = target,
            .optimize = optimize,
        });
        configureCompileStep(unit_tests);

        const run_unit_tests = b.addRunArtifact(unit_tests);

        const step = b.step("test", "Run unit tests");
        step.dependOn(&run_unit_tests.step);

        break :blk step;
    };

    {
        const plugins_path = "plugins";

        var plugins_dir = try std.fs.cwd().openIterableDir(plugins_path, .{ .access_sub_paths = false });
        defer plugins_dir.close();

        var plugins_iter = plugins_dir.iterate();
        while (try plugins_iter.next()) |plugin_dir| {
            const plugin_source = std.Build.LazyPath.relative(b.pathJoin(&.{ plugins_path, plugin_dir.name, "main.zig" }));
            const plugin_target = .{
                .cpu_arch = .wasm32,
                .os_tag = .wasi,
            };

            {
                const exe = b.addExecutable(.{
                    .name = plugin_dir.name,
                    .root_source_file = plugin_source,
                    .target = plugin_target,
                    .optimize = optimize,
                    .linkage = .dynamic,
                });
                configurePluginCompileStep(exe);

                b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "libexec/cizero/plugins" } } }).step);
            }

            {
                const unit_tests = b.addTest(.{
                    .root_source_file = plugin_source,
                    .target = plugin_target,
                    .optimize = optimize,
                });
                configurePluginCompileStep(unit_tests);

                const run_unit_tests = b.addRunArtifact(unit_tests);

                test_step.dependOn(&run_unit_tests.step);
            }
        }
    }
}

fn configureCompileStep(step: *std.Build.Step.Compile) void {
    step.linkLibC();
    step.linkSystemLibrary("wasmtime");
}

fn configurePluginCompileStep(step: *std.Build.Step.Compile) void {
    step.rdynamic = true;
    step.wasi_exec_model = .command;

    step.addAnonymousModule("cizero", .{ .source_file = std.Build.LazyPath.relative("pdk/main.zig") });
}
