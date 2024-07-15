const std = @import("std");

const build_hook = @import("nix-build-hook");

pub const std_options = .{
    .logFn = build_hook.log.logFn,
};

const accept_after_collecting = false;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) (build_hook.log.Action{ .error_info = .{
        .level = .warn,
        .msg = "leaked memory",
        .raw_msg = @tagName(.leak),
    } }).log() catch std.debug.panic("could not log memory leak\n", .{});

    const allocator = gpa.allocator();

    innerMain(allocator) catch |err|
        build_hook.log.logErrorInfo(allocator, .@"error", err, "error: {s}", .{@errorName(err)}) catch |err|
        std.debug.panic("could not log error: {}\n", .{err});
}

// Translated from nix' `src/build-remote/build-remote.cc`,
// which is spawned by `src/libstore/build/derivation-goal.cc`
// and fed mostly in `tryBuildHook()`.
fn innerMain(allocator: std.mem.Allocator) !void {
    {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        const verbosity = try build_hook.parseArgs(&args);
        std.log.debug("log verbosity: {s}", .{@tagName(verbosity)});
    }

    var nix_config, var connection = try build_hook.start(allocator);

    {
        errdefer nix_config.deinit();

        if (std.log.defaultLogEnabled(.debug)) {
            var nix_config_msg = std.ArrayList(u8).init(allocator);
            defer nix_config_msg.deinit();

            var iter = nix_config.iterator();
            while (iter.next()) |entry| {
                try nix_config_msg.appendNTimes(' ', 2);
                try nix_config_msg.appendSlice(entry.key_ptr.*);
                try nix_config_msg.appendSlice(" = ");
                try nix_config_msg.appendSlice(entry.value_ptr.*);
                try nix_config_msg.append('\n');
            }

            std.log.debug("nix config: \n{s}", .{nix_config_msg.items});
        }
    }

    var drv = drv: {
        var ifds_file = ifds_file: {
            defer nix_config.deinit();

            const builders = nix_config.get("builders").?;
            if (builders.len == 0) {
                std.log.err("expected path to write IFDs to in nix config entry `builders` but it is empty", .{});
                return error.NoBuilders;
            }
            if (!std.fs.path.isAbsolute(builders)) {
                std.log.err("path to write IFDs to is not absolute: {s}", .{builders});
                return error.AccessDenied;
            }
            break :ifds_file std.fs.openFileAbsolute(builders, .{ .mode = .write_only }) catch |err| {
                std.log.err("failed to open path to write IFDs to: {s}", .{builders});
                return err;
            };
        };
        defer ifds_file.close();

        if (try ifds_file.getEndPos() != 0) break :drv try connection.readDerivation(allocator);

        const ifds_writer = ifds_file.writer();

        var drvs = std.StringHashMapUnmanaged(build_hook.Derivation){};
        defer {
            // No need to free the keys explicitly
            // because `build_hook.Derivation.drv_path` is used as the key
            // and that is already freed by `build_hook.Derivation.deinit()`.
            var iter = drvs.valueIterator();
            while (iter.next()) |drv|
                drv.deinit(allocator);

            drvs.deinit(allocator);
        }

        while (true) {
            const drv = connection.readDerivation(allocator) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };

            const gop = gop: {
                errdefer drv.deinit(allocator);

                break :gop try drvs.getOrPut(allocator, drv.drv_path);
            };
            if (gop.found_existing) {
                std.debug.assert(drv.am_willing == gop.value_ptr.am_willing);

                std.debug.assert(std.mem.eql(u8, drv.needed_system, gop.value_ptr.needed_system));

                std.debug.assert(std.mem.eql(u8, drv.drv_path, gop.value_ptr.drv_path));

                std.debug.assert(drv.required_features.len == gop.value_ptr.required_features.len);
                for (drv.required_features, gop.value_ptr.required_features) |a, b|
                    std.debug.assert(std.mem.eql(u8, a, b));

                std.log.debug("received postponed drv: {s}", .{drv.drv_path});

                if (accept_after_collecting) break :drv drv;

                drv.deinit(allocator);
            } else {
                gop.value_ptr.* = drv;

                if (comptime std.log.defaultLogEnabled(.debug)) {
                    const drv_json = try std.json.stringifyAlloc(allocator, drv, .{});
                    defer allocator.free(drv_json);

                    std.log.debug("received new drv: {s}", .{drv_json});
                }

                try ifds_writer.writeAll(drv.drv_path);
                try ifds_writer.writeByte('\n');
            }

            try connection.postpone();
        }
    };
    defer drv.deinit(allocator);

    const build_io = try connection.accept(allocator, "ssh://example.com");
    defer build_io.deinit(allocator);

    {
        const build_io_json = try std.json.stringifyAlloc(allocator, build_io, .{});
        defer allocator.free(build_io_json);

        std.log.debug("accepted: {s}", .{build_io_json});
    }
}
