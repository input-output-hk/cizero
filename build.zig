const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    b.enable_wasmtime = true;

    const opts = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe }),
    };

    const lib_mod = b.addModule("lib", .{
        .root_source_file = Build.LazyPath.relative("src/lib.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    configureModule(b, lib_mod, false, opts);

    const cizero_mod = b.addModule("cizero", .{
        .root_source_file = Build.LazyPath.relative("src/Cizero.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    configureModule(b, cizero_mod, true, opts);
    cizero_mod.addImport("lib", lib_mod);

    const cizero_exe = b.addExecutable(.{
        .name = "cizero",
        .root_source_file = Build.LazyPath.relative("src/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    configureModule(b, &cizero_exe.root_module, false, opts);
    cizero_exe.root_module.addImport("cizero", cizero_mod);
    b.installArtifact(cizero_exe);

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

    const run_step = b.step("run", "Run the app");
    {
        const run_exe = b.addRunArtifact(cizero_exe);
        run_exe.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_exe.addArgs(args);

        run_step.dependOn(&run_exe.step);
    }

    const test_step = b.step("test", "Run unit tests");
    {
        const lib_mod_test = b.addTest(.{
            .name = "lib",
            .root_source_file = lib_mod.root_source_file.?,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        configureModule(b, &lib_mod_test.root_module, false, opts);

        const run_lib_mod_test = b.addRunArtifact(lib_mod_test);
        test_step.dependOn(&run_lib_mod_test.step);
    }
    {
        const cizero_mod_test = b.addTest(.{
            .name = "cizero",
            .root_source_file = cizero_mod.root_source_file.?,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        configureModule(b, &cizero_mod_test.root_module, true, opts);
        cizero_mod_test.root_module.addImport("lib", lib_mod);

        const run_cizero_mod_test = b.addRunArtifact(cizero_mod_test);
        test_step.dependOn(&run_cizero_mod_test.step);
    }
    {
        const cizero_exe_test = b.addTest(.{
            .name = "exe",
            .root_source_file = cizero_exe.root_module.root_source_file.?,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        configureModule(b, &cizero_exe_test.root_module, false, opts);
        cizero_exe_test.root_module.addImport("cizero", cizero_mod);

        const run_cizero_exe_test = b.addRunArtifact(cizero_exe_test);
        test_step.dependOn(&run_cizero_exe_test.step);
    }

    const test_pdk_step = b.step("test-pdk", "Run PDK tests");
    if (b.option([]const u8, "plugin", "Path to WASM module of a PDK test plugin")) |plugin_path| {
        const build_options = b.addOptions();
        build_options.addOption([]const u8, "plugin_path", plugin_path);

        const pdk_test = b.addTest(.{
            .name = "PDK",
            .root_source_file = Build.LazyPath.relative("src/plugin/pdk-test.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        configureModule(b, &pdk_test.root_module, false, opts);
        pdk_test.root_module.addOptions("build_options", build_options);
        pdk_test.root_module.addImport("lib", lib_mod);
        pdk_test.root_module.addImport("cizero", cizero_mod);

        const run_pdk_test = b.addRunArtifact(pdk_test);
        test_pdk_step.dependOn(&run_pdk_test.step);
    }
}

fn configureModule(b: *Build, module: *Build.Module, link: bool, opts: anytype) void {
    if (link) {
        module.link_libc = true;
        module.linkSystemLibrary("wasmtime", .{});
    }

    module.addImport("cron", b.dependency("cron", opts).module("cron"));
    module.addImport("datetime", b.dependency("datetime", opts).module("zig-datetime"));
    module.addImport("httpz", b.dependency("httpz", opts).module("httpz"));
    module.addImport("known-folders", b.dependency("known-folders", .{}).module("known-folders"));
    module.addImport("trait", b.dependency("trait", opts).module("zigtrait"));
}
