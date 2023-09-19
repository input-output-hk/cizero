const std = @import("std");

pub fn build(b: *std.Build) !void {
    b.enable_wasmtime = true;

    const source = std.Build.LazyPath.relative("main.zig");

    _ = b.addModule("cizero-pdk", .{ .source_file = source });

    const test_step = b.step("test", "Run unit tests");
    {
        const tests = b.addTest(.{ .root_source_file = source });

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}
