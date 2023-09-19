const std = @import("std");

pub fn build(b: *std.Build) !void {
    b.enable_wasmtime = true;

    const source = std.Build.LazyPath.relative("main.zig");

    _ = b.addModule("cizero-pdk", .{ .source_file = source });

    const unit_tests = b.addTest(.{ .root_source_file = source });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const step = b.step("test", "Run unit tests");
    step.dependOn(&run_unit_tests.step);
}
