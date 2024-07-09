const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const opts = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };

    const deps_opts = .{
        .lib = opts,
        .cizero = .{
            .target = opts.target,
            .release = opts.optimize != .Debug,
        },
        .@"cizero-pdk" = .{
            .release = opts.optimize != .Debug,
        },
    };

    {
        const cizero_run_tls = b.dependency("cizero", deps_opts.cizero).builder.top_level_steps.get("run").?;
        try b.top_level_steps.putNoClobber(b.allocator, cizero_run_tls.step.name, cizero_run_tls);
    }

    const test_step = b.step("test", "Run unit tests");

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
            const install_dir_lenient = InstallDirLenientStep.create(b, .{
                .source_dir = b.path(std.fs.path.relative(b.allocator, b.build_root.path.?, pkg.builder.install_path) catch @panic("OOM")),
                .install_dir = .prefix,
                .install_subdir = "",
            });
            install_dir_lenient.step.name = std.mem.concat(b.allocator, u8, &.{ "install ", dep_name, "/zig-out" }) catch @panic("OOM");
            install_dir_lenient.step.dependOn(pkg_install_step);
            b.getInstallStep().dependOn(&install_dir_lenient.step);
        }

        {
            const pkg_test_step = &pkg.builder.top_level_steps.get("test").?.step;
            pkg_test_step.name = std.mem.concat(b.allocator, u8, &.{ dep_name, " TLS ", pkg_test_step.name }) catch @panic("OOM");

            test_step.dependOn(pkg_test_step);
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

    const test_pdk_step = b.step("test-pdk", "Run PDK tests");
    if (b.option([]const u8, "plugin", "Path to WASM module of a PDK test plugin")) |plugin_path| {
        const CizeroBuild = b.lazyImport(@This(), "cizero") orelse unreachable;

        const cizero_pkg = b.dependencyFromBuildZig(CizeroBuild, deps_opts.cizero);

        const build_options = b.addOptions();
        build_options.addOption([]const u8, "plugin_path", plugin_path);

        const pdk_test = b.addTest(.{
            .name = "PDK",
            .root_source_file = b.path("pdk-test.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        CizeroBuild.addDependencyImports(cizero_pkg.builder, &pdk_test.root_module, opts);
        CizeroBuild.linkSystemLibraries(&pdk_test.root_module);
        pdk_test.root_module.addOptions("build_options", build_options);
        pdk_test.root_module.addImport("cizero", cizero_pkg.module("cizero"));

        const run_pdk_test = b.addRunArtifact(pdk_test);
        test_pdk_step.dependOn(&run_pdk_test.step);
    }
}

/// Like `std.Build.Step.InstallDir`
/// but does nothing instead of returning an error
/// if the source directory does not exist.
const InstallDirLenientStep = struct {
    step: Build.Step,
    inner: *Build.Step.InstallDir,

    pub const base_id = .install_dir_lenient;

    pub fn create(owner: *Build, options: Build.Step.InstallDir.Options) *@This() {
        const self = owner.allocator.create(@This()) catch @panic("OOM");

        const inner = Build.Step.InstallDir.create(owner, options);

        self.* = .{
            .step = Build.Step.init(.{
                .id = inner.step.id,
                .name = inner.step.name,
                .owner = inner.step.owner,
                .makeFn = make,
            }),
            .inner = inner,
        };

        return self;
    }

    fn make(step: *Build.Step, progress_node: *std.Progress.Node) !void {
        const self: *@This() = @fieldParentPtr("step", step);
        const src_dir_path = self.inner.options.source_dir.getPath2(step.owner, step);

        std.fs.accessAbsolute(src_dir_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                step.result_cached = true;
                return;
            },
            else => return err,
        };

        try self.inner.step.makeFn(&self.inner.step, progress_node);
        step.result_cached = self.inner.step.result_cached;
    }
};
