const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    b.enable_wasmtime = true;

    const opts = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe }),
    };

    const module = b.addModule("cizero", .{
        .root_source_file = Build.LazyPath.relative("src/Cizero.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    configureModule(b, module, opts);

    const exe = b.addExecutable(.{
        .name = "cizero",
        .root_source_file = Build.LazyPath.relative("src/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    configureModule(b, &exe.root_module, opts);
    exe.root_module.addImport("cizero", module);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    {
        const run_exe = b.addRunArtifact(exe);
        run_exe.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_exe.addArgs(args);

        run_step.dependOn(&run_exe.step);
    }

    {
        const nix_build_hook_exe = b.addExecutable(.{
            .name = "build-hook",
            .root_source_file = Build.LazyPath.relative("src/components/nix/build-hook/main.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });

        const install_nix_build_hook_exe = b.addInstallArtifact(nix_build_hook_exe, .{ .dest_dir = .{ .override = .{ .custom = "libexec/cizero/components/nix" } } });
        b.getInstallStep().dependOn(&install_nix_build_hook_exe.step);
    }

    const test_step = b.step("test", "Run unit tests");
    {
        const tests = b.addTest(.{
            .root_source_file = module.root_source_file.?,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        configureModule(b, &tests.root_module, opts);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
    {
        const tests = b.addTest(.{
            .name = "exe",
            .root_source_file = exe.root_module.root_source_file.?,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        configureModule(b, &tests.root_module, opts);
        tests.root_module.addImport("cizero", module);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    const test_pdk_step = b.step("test-pdk", "Run PDK tests");
    if (b.option([]const u8, "plugin", "Path to WASM module of a PDK test plugin")) |plugin_path| {
        const build_options = b.addOptions();
        build_options.addOption([]const u8, "plugin_path", plugin_path);

        const tests = b.addTest(.{
            .name = "PDK",
            .root_source_file = Build.LazyPath.relative("src/plugin/pdk-test.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        configureModule(b, &tests.root_module, opts);
        tests.root_module.addImport("cizero", module);
        tests.root_module.addOptions("build_options", build_options);

        const run_tests = b.addRunArtifact(tests);
        test_pdk_step.dependOn(&run_tests.step);
    }
}

fn configureModule(b: *Build, module: *Build.Module, opts: anytype) void {
    module.link_libc = true;
    module.linkSystemLibrary("wasmtime", .{});

    module.addImport("cron", b.dependency("cron", opts).module("cron"));
    module.addImport("datetime", b.dependency("datetime", opts).module("zig-datetime"));
    module.addImport("httpz", b.dependency("httpz", opts).module("httpz"));
    module.addImport("known-folders", b.dependency("known-folders", .{}).module("known-folders"));
    module.addImport("trait", b.dependency("trait", opts).module("zigtrait"));
}
