const std = @import("std");

const utils = @import("utils").utils;

pub fn build(b: *std.Build) !void {
    b.enable_wasmtime = true;

    const opts = .{
        .target = b.standardTargetOptions(.{ .default_target = .{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
        } }),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall }),
    };

    const module = b.addModule("cizero-pdk", .{
        .root_source_file = b.path("main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = imports: {
            const cizero_types_mod = b.dependency("cizero", .{
                .target = opts.target,
                .release = opts.optimize != .Debug,
            }).module("cizero-types");

            // Getting from `import_table` as a workaround for "file exists in multiple modules" error.
            const utils_mod = cizero_types_mod.import_table.get("utils").?;

            break :imports &.{
                .{ .name = "cizero", .module = cizero_types_mod },
                .{ .name = "utils", .module = utils_mod },
                .{ .name = "trait", .module = b.dependency("trait", opts).module("zigtrait") },
                .{ .name = "s2s", .module = b.dependency("s2s", opts).module("s2s") },
            };
        },
    });

    const test_step = b.step("test", "Run unit tests");
    {
        const tests = b.addTest(.{ .root_module = module });
        configureCompileStep(tests);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    _ = utils.addCheckTls(b);
}

fn configureCompileStep(step: *std.Build.Step.Compile) void {
    step.rdynamic = true;
    step.wasi_exec_model = .command;
}
