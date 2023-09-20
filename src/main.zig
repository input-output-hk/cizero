const std = @import("std");

const Plugin = @import("Plugin.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const binary = try std.fs.cwd().readFileAlloc(alloc, args[1], std.math.maxInt(usize));
    defer alloc.free(binary);

    const plugin = try Plugin.init(binary);
    defer plugin.deinit();

    try std.testing.expectEqual(@as(i32, 233), try plugin.fib(12));
    try std.testing.expectEqual(@as(c_int, 2), try plugin.main());
}

test {
    _ = Plugin;
}
