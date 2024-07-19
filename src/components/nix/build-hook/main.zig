const std = @import("std");

const build_hook = @import("nix-build-hook");

pub const std_options = .{
    .logFn = build_hook.log.logFn,
};

const accept_after_collecting = true;

/// Symlink build outputs into the eval store to save disk space.
/// Only works if the eval store is a chroot store!
const symlink_ifds_into_eval_store = true;

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
    defer nix_config.deinit();

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

    var drv = drv: {
        var ifds_file = ifds_file: {
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

        if (accept_after_collecting and
            try ifds_file.getEndPos() != 0)
            break :drv try connection.readDerivation(allocator);

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
                if (std.debug.runtime_safety) {
                    std.debug.assert(drv.am_willing == gop.value_ptr.am_willing);

                    std.debug.assert(std.mem.eql(u8, drv.needed_system, gop.value_ptr.needed_system));

                    std.debug.assert(std.mem.eql(u8, drv.drv_path, gop.value_ptr.drv_path));

                    std.debug.assert(drv.required_features.len == gop.value_ptr.required_features.len);
                    for (drv.required_features, gop.value_ptr.required_features) |a, b|
                        std.debug.assert(std.mem.eql(u8, a, b));
                }

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

    const store = nix_config.get("store").?;

    // Free all the memory in `nix_config` except the entries we still need.
    {
        var iter = nix_config.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "store"))
                continue;

            nix_config.remove(entry.key_ptr.*);
        }
    }

    const build_io = try connection.accept(allocator, "auto");
    defer build_io.deinit(allocator);

    {
        const build_io_json = try std.json.stringifyAlloc(allocator, build_io, .{});
        defer allocator.free(build_io_json);

        std.log.debug("accepted: {s}", .{build_io_json});
    }

    var installable = std.ArrayList(u8).init(allocator);
    defer installable.deinit();

    try installable.appendSlice(drv.drv_path);
    try installable.append('^');
    for (build_io.wanted_outputs, 0..) |wanted_output, idx| {
        if (idx != 0) try installable.append(',');
        try installable.appendSlice(wanted_output);
    }

    std.log.debug("installable: {s}", .{installable.items});

    {
        var process = std.process.Child.init(&.{
            "nix",
            "copy",
            "-" ++ ("v" ** @intFromEnum(build_hook.log.Action.Verbosity.vomit)),
            "--log-format",
            "internal-json",
            "--no-check-sigs",
            "--from",
            store,
            drv.drv_path,
        }, allocator);

        const term = try process.spawnAndWait();
        if (term != .Exited or term.Exited != 0) {
            std.log.err("`nix copy --from {s} {s}` failed: {}", .{ store, drv.drv_path, term });
            return error.NixCopy;
        }
    }

    {
        var process = std.process.Child.init(&.{
            "nix",
            "build",
            "-" ++ ("v" ** @intFromEnum(build_hook.log.Action.Verbosity.vomit)),
            "--log-format",
            "internal-json",
            "--no-link",
            "--print-build-logs",
            installable.items,
        }, allocator);

        const term = try process.spawnAndWait();
        if (term != .Exited or term.Exited != 0) {
            std.log.err("`nix build {s}` failed: {}", .{ installable.items, term });
            return error.NixBuild;
        }
    }

    var output_paths = std.BufSet.init(allocator);
    defer output_paths.deinit();
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "nix", "derivation", "show", installable.items },
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        if (result.term != .Exited or result.term.Exited != 0) {
            std.log.err("`nix derivation show {s}` failed: {}\nstdout: {s}\nstderr: {s}", .{ installable.items, result.term, result.stdout, result.stderr });
            return error.NixDerivationShow;
        }

        const parsed = std.json.parseFromSlice(std.json.ArrayHashMap(struct {
            outputs: std.json.ArrayHashMap(struct { path: []const u8 }),
        }), allocator, result.stdout, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.err("Failed to parse output of `nix derivation show {s}`: {s}\nstdout: {s}\nstderr: {s}", .{ installable.items, @errorName(err), result.stdout, result.stderr });
            return err;
        };
        defer parsed.deinit();

        for (parsed.value.map.values()) |drv_info|
            for (drv_info.outputs.map.values()) |output|
                try output_paths.insert(output.path);
    }

    if (symlink_ifds_into_eval_store) {
        const dump_argv_head = &.{ "nix-store", "--dump-db" };
        var dump_argv = dump_argv: {
            var dump_argv = try std.ArrayList([]const u8).initCapacity(allocator, dump_argv_head.len + output_paths.count());
            dump_argv.appendSliceAssumeCapacity(dump_argv_head);
            break :dump_argv dump_argv;
        };
        defer dump_argv.deinit();

        {
            var output_paths_iter = output_paths.iterator();
            while (output_paths_iter.next()) |output_path| {
                try dump_argv.append(output_path.*);

                if (std.debug.runtime_safety) std.debug.assert(std.mem.startsWith(
                    u8,
                    output_path.*,
                    std.fs.path.sep_str ++ "nix" ++
                        std.fs.path.sep_str ++ "store" ++
                        std.fs.path.sep_str,
                ));

                const sym_link_path = try std.fs.path.join(allocator, &.{ store, output_path.* });
                std.log.debug("linking: {s} -> {s}", .{ sym_link_path, output_path.* });
                defer allocator.free(sym_link_path);
                try std.fs.symLinkAbsolute(output_path.*, sym_link_path, .{});
            }
        }

        std.log.debug("importing outputs into eval store: {s} <- {s}", .{ store, dump_argv.items[dump_argv_head.len..] });

        // XXX cannot pipe between the processes directly due to https://github.com/ziglang/zig/issues/7738

        const dump_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = dump_argv.items,
            .max_output_bytes = 1024 * 512,
        });
        defer {
            allocator.free(dump_result.stdout);
            allocator.free(dump_result.stderr);
        }

        if (dump_result.term != .Exited or dump_result.term.Exited != 0) {
            std.log.err("`nix-store --dump-db` failed: {}\nstdout: {s}\nstderr: {s}", .{ dump_result.term, dump_result.stdout, dump_result.stderr });
            return error.NixStoreDumpDb;
        }

        {
            // XXX `std.process.execv()` instead?
            var load_process = std.process.Child.init(&.{ "nix-store", "--load-db", "--store", store }, allocator);
            load_process.stdin_behavior = .Pipe;
            load_process.stdout_behavior = .Pipe;
            load_process.stderr_behavior = .Pipe;

            try load_process.spawn();

            try load_process.stdin.?.writeAll(dump_result.stdout);
            load_process.stdin.?.close();
            load_process.stdin = null;

            var load_process_stdout = std.ArrayList(u8).init(allocator);
            defer load_process_stdout.deinit();

            var load_process_stderr = std.ArrayList(u8).init(allocator);
            defer load_process_stderr.deinit();

            try load_process.collectOutput(&load_process_stdout, &load_process_stderr, 1024 * 512);

            const load_process_term = try load_process.wait();

            if (load_process_term != .Exited or load_process_term.Exited != 0) {
                std.log.err("`nix-store --load-db` failed: {}\nstdout: {s}\nstderr: {s}", .{ load_process_term, load_process_stdout.items, load_process_stderr.items });
                return error.NixStoreLoadDb;
            }
        }
    } else {
        // XXX `std.process.execve()` instead?
        var process = std.process.Child.init(&.{
            "nix",
            "copy",
            "-" ++ ("v" ** @intFromEnum(build_hook.log.Action.Verbosity.vomit)),
            "--log-format",
            "internal-json",
            "--no-check-sigs",
            "--to",
            store,
            installable.items,
        }, allocator);

        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();
        process.env_map = &env;
        {
            const key = try allocator.dupe(u8, "NIX_HELD_LOCKS");
            errdefer allocator.free(key);

            var value = std.ArrayList(u8).init(allocator);
            errdefer value.deinit();
            {
                var iter = output_paths.iterator();
                var first = true;
                while (iter.next()) |output_path| {
                    if (first)
                        first = false
                    else
                        try value.append(':');

                    try value.appendSlice(output_path.*);
                }
            }

            std.log.debug("NIX_HELD_LOCKS={s}", .{value.items});

            try env.putMove(key, try value.toOwnedSlice());
        }

        const term = try process.spawnAndWait();
        if (term != .Exited or term.Exited != 0) {
            std.log.err("`nix copy --to {s} {s}` failed: {}", .{ store, installable.items, term });
            return error.NixCopy;
        }
    }
}
