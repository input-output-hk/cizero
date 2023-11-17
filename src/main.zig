const std = @import("std");

const Cizero = @import("Cizero.zig");
const Plugin = @import("Plugin.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    const allocator = gpa.allocator();

    var cizero = try Cizero.init(allocator);
    defer cizero.deinit();

    {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        _ = args.next(); // discard executable (not a plugin)
        while (args.next()) |arg|
            _ = try cizero.registry.registerPlugin(.{ .path = arg });
    }

    try cizero.run();
}

test {
    std.testing.refAllDeclsRecursive(@This());
    _ = @import("mem.zig");
}
