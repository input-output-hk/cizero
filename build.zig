const std = @import("std");
const Build = std.Build;

const utils = @import("utils").utils;
const cizero_build = @import("cizero");

pub fn build(b: *Build) !void {
    const opts = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };

    const deps_opts = .{
        .cizero = .{
            .target = opts.target,
            .release = opts.optimize != .Debug,
        },
        .@"cizero-pdk" = .{
            .release = opts.optimize != .Debug,
        },
        .@"nix-sigstop" = .{
            .target = opts.target,
            .release = opts.optimize != .Debug,
        },
    };

    {
        const cizero_run_tls = b.dependency("cizero", deps_opts.cizero).builder.top_level_steps.get("run").?;
        try b.top_level_steps.putNoClobber(b.allocator, cizero_run_tls.step.name, cizero_run_tls);

        for (cizero_run_tls.step.dependencies.items) |dep_step| {
            if (dep_step.id != .run) continue;

            if (b.args) |args| {
                const run = dep_step.cast(Build.Step.Run).?;
                run.addArgs(args);
            }
        }
    }

    inline for (comptime std.meta.fieldNames(@TypeOf(deps_opts))) |dep_name| {
        const dep_opts = @field(deps_opts, dep_name);

        const pkg = b.dependency(dep_name, dep_opts);

        if (pkg.builder.enable_darling) b.enable_darling = true;
        if (pkg.builder.enable_qemu) b.enable_qemu = true;
        if (pkg.builder.enable_rosetta) b.enable_rosetta = true;
        if (pkg.builder.enable_wasmtime) b.enable_wasmtime = true;
        if (pkg.builder.enable_wine) b.enable_wine = true;

        {
            const pkg_install_step = pkg.builder.getInstallStep();
            pkg_install_step.name = std.mem.concat(b.allocator, u8, &.{ dep_name, " TLS ", pkg_install_step.name }) catch @panic("OOM");

            // Move the output of the `pkg`'s step into our install directory to produce one top-level merged `zig-out`.
            const install_dir_lenient = utils.InstallDirLenientStep.create(b, .{
                .source_dir = b.path(std.fs.path.relative(b.allocator, b.build_root.path.?, pkg.builder.install_path) catch @panic("OOM")),
                .install_dir = .prefix,
                .install_subdir = "",
            });
            install_dir_lenient.step.name = std.mem.concat(b.allocator, u8, &.{ "install ", dep_name, "/zig-out" }) catch @panic("OOM");
            install_dir_lenient.step.dependOn(pkg_install_step);
            b.getInstallStep().dependOn(&install_dir_lenient.step);
        }

        {
            var pkg_mod_iter = pkg.builder.modules.iterator();
            while (pkg_mod_iter.next()) |pkg_mod_entry|
                b.modules.put(
                    pkg_mod_entry.key_ptr.*,
                    pkg_mod_entry.value_ptr.*,
                ) catch @panic("OOM");
        }
    }

    {
        var tls_names = allTopLevelStepNames(b, deps_opts) catch @panic("OOM");
        defer tls_names.deinit();

        tls_names.remove("install");
        tls_names.remove("run");

        var tls_names_iter = tls_names.iterator();
        while (tls_names_iter.next()) |tls_name| {
            const aggregate_step = if (b.top_level_steps.get(tls_name.*)) |tls|
                &tls.step
            else
                b.step(tls_name.*, std.mem.concat(b.allocator, u8, &.{ "Run all subprojects' `", tls_name.*, "` top-level steps" }) catch @panic("OOM"));

            inline for (comptime std.meta.fieldNames(@TypeOf(deps_opts))) |dep_name| {
                const dep_opts = @field(deps_opts, dep_name);

                const pkg = b.dependency(dep_name, dep_opts);

                if (pkg.builder.top_level_steps.get(tls_name.*)) |pkg_tls| {
                    const pkg_tls_step = &pkg_tls.step;
                    pkg_tls_step.name = std.mem.concat(b.allocator, u8, &.{ dep_name, " TLS ", pkg_tls_step.name }) catch @panic("OOM");

                    aggregate_step.dependOn(pkg_tls_step);
                }
            }
        }
    }

    const test_pdk_step = b.step("test-pdk", "Run PDK tests");
    if (b.option([]const u8, "plugin", "Path to WASM module of a PDK test plugin")) |plugin_path| {
        const cizero_pkg = b.dependencyFromBuildZig(cizero_build, deps_opts.cizero);

        const build_options = b.addOptions();
        build_options.addOption([]const u8, "plugin_path", plugin_path);

        const pdk_test = b.addTest(.{
            .name = "PDK",
            .root_source_file = b.path("pdk-test.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        cizero_build.addDependencyImports(cizero_pkg.builder, &pdk_test.root_module, opts);
        cizero_build.linkSystemLibraries(&pdk_test.root_module);
        pdk_test.root_module.addOptions("build_options", build_options);
        pdk_test.root_module.addImport("cizero", cizero_pkg.module("cizero"));

        const run_pdk_test = b.addRunArtifact(pdk_test);
        test_pdk_step.dependOn(&run_pdk_test.step);
    }
}

fn allTopLevelStepNames(b: *Build, deps_opts: anytype) std.mem.Allocator.Error!std.BufSet {
    var names = std.BufSet.init(b.allocator);
    errdefer names.deinit();

    inline for (comptime std.meta.fieldNames(@TypeOf(deps_opts))) |dep_name| {
        const dep_opts = @field(deps_opts, dep_name);

        const pkg = b.dependency(dep_name, dep_opts);

        for (pkg.builder.top_level_steps.keys()) |name|
            try names.insert(name);
    }

    return names;
}
