const builtin = @import("builtin");
const std = @import("std");
const zqlite = @import("zqlite");

const Cizero = @import("cizero");

var cizero: *Cizero = undefined;
var shell_fg: ?bool = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    defer if (gpa.deinit() == .leak) std.log.err("leaked memory", .{});
    const allocator = gpa.allocator();

    const db_path = "cizero.sqlite";

    if (builtin.mode == .Debug) {
        const cwd = std.fs.cwd();
        cwd.deleteFile(db_path) catch {};
        cwd.deleteFile(db_path ++ "-wal") catch {};
        cwd.deleteFile(db_path ++ "-shm") catch {};
    }

    cizero = try Cizero.init(allocator, .{
        .path = db_path,
        .flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.NoMutex,
    });
    defer cizero.deinit();

    shell_fg = if (std.io.getStdIn().isTty()) true else null;

    {
        const sa = std.os.Sigaction{
            .handler = .{ .handler = struct {
                fn handler(sig: c_int) callconv(.C) void {
                    std.log.info("graceful shutdown requested via signal {d}", .{sig});
                    if (shell_fg) |*fg| {
                        fg.* = false;
                        std.log.info("cizero is shutting down in the background", .{});
                    }
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
        while (args.next()) |arg| {
            const wasm = try std.fs.cwd().readFileAlloc(allocator, arg, std.math.maxInt(usize));
            defer allocator.free(wasm);

            _ = try cizero.registry.registerPlugin(std.fs.path.stem(arg), wasm);
        }
    }

    try cizero.run();

    if (shell_fg) |fg| if (!fg) std.log.info("cizero exited", .{});
}
