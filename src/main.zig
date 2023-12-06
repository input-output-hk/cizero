const std = @import("std");

const Cizero = @import("Cizero.zig");
const Plugin = @import("Plugin.zig");

var cizero: *Cizero = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    defer if (gpa.deinit() == .leak) std.log.err("leaked memory", .{});
    const allocator = gpa.allocator();

    cizero = try Cizero.init(allocator);
    defer cizero.deinit();

    {
        const sa = std.os.Sigaction{
            .handler = .{ .handler = struct {
                fn handler(sig: c_int) callconv(.C) void {
                    std.log.info("graceful shutdown requested via signal {d}", .{sig});
                    cizero.stop();
                }
            }.handler },
            .mask = std.os.empty_sigset,
            .flags = std.os.SA.RESETHAND,
        };
        try std.os.sigaction(std.os.SIG.TERM, &sa, null);
        try std.os.sigaction(std.os.SIG.INT, &sa, null);
    }

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
