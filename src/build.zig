const std = @import("std");
const Build = std.Build;

const utils = @import("utils").utils;

pub const Options = struct {
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(b: *Build) !void {
    b.enable_wasmtime = true;

    const options = Options{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe }),
    };

    const cizero_mod = b.addModule("cizero", .{
        .root_source_file = b.path("Cizero.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    addDependencyImports(b, cizero_mod, options);

    const cizero_exe = b.addExecutable(.{
        .name = "cizero",
        .root_source_file = b.path("main.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    addDependencyImports(b, &cizero_exe.root_module, options);
    linkSystemLibraries(&cizero_exe.root_module);
    cizero_exe.root_module.addImport("cizero", cizero_mod);
    b.installArtifact(cizero_exe);

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
            .name = "cizero (mod)",
            .root_source_file = cizero_mod.root_source_file.?,
            .target = options.target,
            .optimize = options.optimize,
        });
        addDependencyImports(b, &cizero_mod_test.root_module, options);
        linkSystemLibraries(&cizero_mod_test.root_module);

        const run_cizero_mod_test = b.addRunArtifact(cizero_mod_test);
        test_step.dependOn(&run_cizero_mod_test.step);
    }
    {
        const cizero_exe_test = b.addTest(.{
            .name = "cizero (exe)",
            .root_source_file = cizero_exe.root_module.root_source_file.?,
            .target = options.target,
            .optimize = options.optimize,
        });
        addDependencyImports(b, &cizero_exe_test.root_module, options);
        cizero_exe_test.root_module.addImport("cizero", cizero_mod);

        const run_cizero_exe_test = b.addRunArtifact(cizero_exe_test);
        test_step.dependOn(&run_cizero_exe_test.step);
    }

    _ = utils.addCheckTls(b);
}

pub fn addDependencyImports(b: *Build, module: *Build.Module, options: Options) void {
    module.addImport("utils", b.dependency("utils", .{
        .target = options.target,
        .optimize = options.optimize,
        .zqlite = true,
    }).module("utils"));
    module.addImport("trait", b.dependency("trait", options).module("zigtrait"));
    module.addImport("args", b.dependency("args", options).module("args"));
    module.addImport("cron", b.dependency("cron", options).module("cron"));
    module.addImport("datetime", b.dependency("datetime", options).module("zig-datetime"));
    module.addImport("httpz", b.dependency("httpz", options).module("httpz"));
    module.addImport("known-folders", b.dependency("known-folders", options).module("known-folders"));
    // Need to use `lazyDependency()` due to https://github.com/ziglang/zig/issues/21771
    module.addImport("zqlite", (b.lazyDependency("zqlite", options) orelse unreachable).module("zqlite"));
}

pub fn linkSystemLibraries(module: *Build.Module) void {
    module.link_libc = true;
    module.linkSystemLibrary("wasmtime", .{});
    module.linkSystemLibrary("sqlite3", .{});
    module.linkSystemLibrary("whereami", .{});
}
