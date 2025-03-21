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

    const utils_mod = b.dependency("utils", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("utils");

    const translate_c_mod = translate_c_mod: {
        const translate_c = b.addTranslateC(.{
            .root_source_file = b.path("c.h"),
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
        });
        try utils.addNixIncludePaths(translate_c);
        break :translate_c_mod translate_c.createModule();
    };
    translate_c_mod.linkSystemLibrary("wasmtime", .{});
    translate_c_mod.linkSystemLibrary("sqlite3", .{});
    translate_c_mod.linkSystemLibrary("whereami", .{});

    // This only exists so that the Zig PDK can import these types.
    // They should ideally live directly in `cizero_mod`.
    // Since Zig 0.14.0 it cannot import `cizero_mod` anymore
    // because that does not compile on WASI.
    // I suppose some part of the compiler became more eager
    // because it worked previously
    // as long as you did not reference the incompatible types.
    const cizero_types_mod = b.addModule("cizero-types", .{
        .root_source_file = b.path("types.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "utils", .module = utils_mod },
        },
    });

    const cizero_mod = b.addModule("cizero", .{
        .root_source_file = b.path("Cizero.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "c", .module = translate_c_mod },
            .{ .name = "types", .module = cizero_types_mod },
            .{ .name = "utils", .module = utils_mod },
            .{ .name = "trait", .module = b.dependency("trait", options).module("zigtrait") },
            .{ .name = "cron", .module = b.dependency("cron", options).module("cron") },
            .{ .name = "datetime", .module = b.dependency("datetime", options).module("datetime") },
            .{ .name = "httpz", .module = b.dependency("httpz", options).module("httpz") },
            .{ .name = "known-folders", .module = b.dependency("known-folders", options).module("known-folders") },
            .{ .name = "zqlite", .module = b.dependency("zqlite", options).module("zqlite") },
            .{ .name = "zqlite-typed", .module = b.dependency("zqlite-typed", options).module("zqlite-typed") },
        },
    });

    const cizero_exe = b.addExecutable(.{
        .name = "cizero",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "cizero", .module = cizero_mod },
                .{ .name = "utils", .module = utils_mod },
                .{ .name = "args", .module = b.dependency("args", options).module("args") },
                .{ .name = "zqlite", .module = b.dependency("zqlite", options).module("zqlite") },
                .{ .name = "zqlite-typed", .module = b.dependency("zqlite-typed", options).module("zqlite-typed") },
            },
        }),
    });
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
            .root_module = cizero_mod,
        });

        const run_cizero_mod_test = b.addRunArtifact(cizero_mod_test);
        test_step.dependOn(&run_cizero_mod_test.step);
    }
    {
        const cizero_exe_test = b.addTest(.{
            .name = "cizero (exe)",
            .root_module = cizero_exe.root_module,
        });

        const run_cizero_exe_test = b.addRunArtifact(cizero_exe_test);
        test_step.dependOn(&run_cizero_exe_test.step);
    }

    _ = utils.addCheckTls(b);
}
