const std = @import("std");
const Build = std.Build;

const lib = @import("lib").lib;

pub fn build(b: *Build) !void {
    b.enable_wasmtime = true;

    const opts = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe }),
    };

    const cizero_mod = b.addModule("cizero", .{
        .root_source_file = b.path("Cizero.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    addDependencyImports(b, cizero_mod, opts);

    const cizero_exe = b.addExecutable(.{
        .name = "cizero",
        .root_source_file = b.path("main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    addDependencyImports(b, &cizero_exe.root_module, opts);
    linkSystemLibraries(&cizero_exe.root_module);
    cizero_exe.root_module.addImport("cizero", cizero_mod);
    b.installArtifact(cizero_exe);

    {
        const nix_build_hook_exe = b.addExecutable(.{
            .name = "build-hook",
            .root_source_file = b.path("components/nix/build-hook/main.zig"),
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
        const cizero_mod_test = b.addTest(.{
            .name = "cizero",
            .root_source_file = cizero_mod.root_source_file.?,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        addDependencyImports(b, &cizero_mod_test.root_module, opts);
        linkSystemLibraries(&cizero_mod_test.root_module);

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
        addDependencyImports(b, &cizero_exe_test.root_module, opts);
        cizero_exe_test.root_module.addImport("cizero", cizero_mod);

        const run_cizero_exe_test = b.addRunArtifact(cizero_exe_test);
        test_step.dependOn(&run_cizero_exe_test.step);
    }

    _ = lib.addCheckTls(b);
}

pub fn addDependencyImports(b: *Build, module: *Build.Module, opts: anytype) void {
    const lib_mod = b.dependency("lib", opts).module("lib");

    module.addImport("lib", lib_mod);
    module.addImport("trait", lib_mod.import_table.get("trait").?);
    module.addImport("cron", b.dependency("cron", opts).module("cron"));
    module.addImport("datetime", b.dependency("datetime", opts).module("zig-datetime"));
    module.addImport("httpz", b.dependency("httpz", opts).module("httpz"));
    module.addImport("known-folders", b.dependency("known-folders", .{}).module("known-folders"));
    module.addImport("zqlite", b.dependency("zqlite", opts).module("zqlite"));
}

pub fn linkSystemLibraries(module: *Build.Module) void {
    module.link_libc = true;
    module.linkSystemLibrary("wasmtime", .{});
    module.linkSystemLibrary("sqlite3", .{});
    module.linkSystemLibrary("whereami", .{});
}
