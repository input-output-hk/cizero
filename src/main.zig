const builtin = @import("builtin");
const std = @import("std");
const args = @import("args");
const zqlite = @import("zqlite");

const Cizero = @import("cizero");

pub const utils_zqlite_options = .{
    .log_scope = .sql,
};

var cizero: *Cizero = undefined;
var shell_fg: ?bool = null;

const Options = struct {
    @"nix-exe": []const u8 = "nix",

    pub const meta = .{
        .option_docs = .{
            .@"nix-exe" = "Nix executable name. Useful to run a wrapper like nix-sigstop.",
        },
    };
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    defer if (gpa.deinit() == .leak) std.log.err("leaked memory", .{});
    const allocator = gpa.allocator();

    const options = args.parseForCurrentProcess(Options, allocator, .print) catch |err| if (err == error.InvalidArguments) {
        try args.printHelp(Options, "cizero PLUGIN...", std.io.getStdErr().writer());
        return 1;
    } else return err;
    defer options.deinit();

    cizero = cizero: {
        const db_path = try Cizero.fs.dbPathZ(allocator);
        defer allocator.free(db_path);

        if (std.fs.path.dirname(db_path)) |path| try std.fs.cwd().makePath(path);

        break :cizero try Cizero.init(allocator, .{
            .db = .{
                .path = db_path,
                .flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.NoMutex,
            },
            .nix = .{
                .exe = options.options.@"nix-exe",
            },
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

    for (options.positionals) |plugin_path|
        try registerPlugin(allocator, plugin_path);

    cizero.wait_group.wait();

    if (shell_fg) |fg| if (!fg) std.log.info("cizero exited", .{});

    return 0;
}

fn registerPlugin(allocator: std.mem.Allocator, plugin_path: []const u8) !void {
    const name = std.fs.path.stem(plugin_path);

    errdefer |err| std.log.err("failed to register plugin {s}: {s}", .{ name, @errorName(err) });

    const wasm = try std.fs.cwd().readFileAlloc(allocator, plugin_path, std.math.maxInt(usize));
    defer allocator.free(wasm);

    try cizero.registry.registerPlugin(name, wasm);
}
