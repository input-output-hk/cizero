const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const opts = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };

    const test_step = b.step("test", "Run unit tests");

    inline for (.{
        .{ "lib", opts },
        .{ "cizero", .{
            .target = opts.target,
            .release = opts.optimize != .Debug,
        } },
        .{ "cizero-pdk", .{
            .release = opts.optimize != .Debug,
        } },
    }) |dep_entry| {
        const dep_name, const dep_opts = dep_entry;

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
            install_dir_lenient.step.dependOn(pkg.builder.getInstallStep());
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
