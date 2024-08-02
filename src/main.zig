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

    cizero = cizero: {
        const db_path = try Cizero.fs.dbPathZ(allocator);
        defer allocator.free(db_path);

        if (std.fs.path.dirname(db_path)) |path| try std.fs.cwd().makePath(path);

        break :cizero try Cizero.init(allocator, .{
            .path = db_path,
            .flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.NoMutex,
        });
    };
    defer cizero.deinit();

    shell_fg = if (std.io.getStdIn().isTty()) true else null;

    {
        const sa = std.posix.Sigaction{
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
            .mask = std.posix.empty_sigset,
            .flags = std.posix.SA.RESETHAND,
        };
        try std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
        try std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    }

    errdefer {
        std.log.info("shutting down…", .{});
        cizero.stop();
        cizero.wait_group.wait();
    }

    cizero.start() catch |err| {
        std.log.err("failed to start: {s}", .{@errorName(err)});
        return err;
    };

    registerPlugins(allocator) catch |err| {
        std.log.err("failed to register plugins: {s}", .{@errorName(err)});
        return err;
    };

    cizero.wait_group.wait();

    if (shell_fg) |fg| if (!fg) std.log.info("cizero exited", .{});
}

fn registerPlugins(allocator: std.mem.Allocator) !void {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const cwd = std.fs.cwd();

    std.debug.assert(args.skip()); // discard executable (not a plugin)
    while (args.next()) |arg| {
        const name = std.fs.path.stem(arg);

        errdefer |err| std.log.err("failed to register plugin {s}: {s}", .{ name, @errorName(err) });

        const wasm = try cwd.readFileAlloc(allocator, arg, std.math.maxInt(usize));
        defer allocator.free(wasm);

        try cizero.registry.registerPlugin(name, wasm);
    }
}
