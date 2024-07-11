const std = @import("std");

const log = @import("log.zig");
const protocol = @import("protocol.zig");

const stdin = std.io.getStdIn().reader();
const stderr = std.io.getStdErr().writer();

pub const std_options = .{
    .logFn = log.logFn,
};

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) (log.Action{ .error_info = .{
        .level = .warn,
        .msg = "leaked memory",
        .raw_msg = @tagName(.leak),
    } }).log() catch std.debug.panic("could not log memory leak\n", .{});

    const allocator = gpa.allocator();

    innerMain(allocator) catch |err|
        log.logErrorInfo(allocator, .@"error", err, "error: {s}", .{@errorName(err)}) catch |err|
        std.debug.panic("could not log error: {}\n", .{err});
}

// Translated from nix' `src/build-remote/build-remote.cc`,
// which is spawned by `src/libstore/build/derivation-goal.cc`
// and fed mostly in `tryBuildHook()`.
fn innerMain(allocator: std.mem.Allocator) !void {
    {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        _ = args.next();

        const verbosity: log.Action.Verbosity = @enumFromInt(std.fmt.parseUnsigned(std.meta.Tag(log.Action.Verbosity), args.next().?, 10) catch |err| switch (err) {
            error.Overflow => @intFromEnum(log.Action.Verbosity.vomit),
            else => return err,
        });
        std.log.debug("log verbosity: {s}", .{@tagName(verbosity)});
    }

    var settings = try protocol.readStringStringMap(allocator, stdin);
    defer settings.deinit(allocator);

    if (std.log.defaultLogEnabled(.debug)) {
        var settings_msg = std.ArrayList(u8).init(allocator);
        defer settings_msg.deinit();

        var iter = settings.map.iterator();
        while (iter.next()) |entry| {
            try settings_msg.appendNTimes(' ', 2);
            try settings_msg.appendSlice(entry.key_ptr.*);
            try settings_msg.appendSlice(" = ");
            try settings_msg.appendSlice(entry.value_ptr.*);
            try settings_msg.append('\n');
        }

        std.log.debug("nix config: \n{s}", .{settings_msg.items});
    }

    var ifds_file = ifds_file: {
        const builders = settings.map.get("builders").?;
        if (builders.len == 0) {
            std.log.err("expected path to write IFDs to in nix config entry `builders` but it is empty", .{});
            return error.NoBuilders;
        }
        if (!std.fs.path.isAbsolute(builders)) {
            std.log.err("path in nix config entry `builders` is not absolute: {s}", .{builders});
            return error.AccessDenied;
        }
        break :ifds_file std.fs.openFileAbsolute(builders, .{ .mode = .write_only }) catch |err| {
            std.log.err("failed to open path in nix config entry `builders`: {s}", .{builders});
            return err;
        };
    };
    defer ifds_file.close();

    const ifds_writer = ifds_file.writer();

    const Drv = struct {
        am_willing: bool,
        needed_system: []const u8,
        drv_path: []const u8,
        required_features: []const []const u8,

        pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
            alloc.free(self.needed_system);

            alloc.free(self.drv_path);

            for (self.required_features) |feature| alloc.free(feature);
            alloc.free(self.required_features);
        }
    };

    var drvs = std.StringHashMapUnmanaged(Drv){};
    defer {
        // No need to free the keys explicitly
        // because `Drv.drv_path` is used as the key
        // and that is already freed by `Drv.deinit()`.
        var iter = drvs.valueIterator();
        while (iter.next()) |drv|
            drv.deinit(allocator);

        drvs.deinit(allocator);
    }

    while (true) {
        {
            const command = protocol.readPacket(allocator, stdin) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            defer allocator.free(command);

            if (!std.mem.eql(u8, command, "try")) {
                std.log.debug("received unexpected command \"{s}\", expected \"try\"", .{std.fmt.fmtSliceEscapeLower(command)});
                return;
            }
        }

        const drv = blk: {
            const am_willing = try protocol.readBool(stdin);
            const needed_system = try protocol.readPacket(allocator, stdin);
            const drv_path = try protocol.readPacket(allocator, stdin);
            const required_features = try protocol.readPackets(allocator, stdin);

            const gop = try drvs.getOrPut(allocator, drv_path);

            if (gop.found_existing) {
                std.debug.assert(am_willing == gop.value_ptr.am_willing);

                std.debug.assert(std.mem.eql(u8, needed_system, gop.value_ptr.needed_system));

                std.debug.assert(std.mem.eql(u8, drv_path, gop.value_ptr.drv_path));

                std.debug.assert(required_features.len == gop.value_ptr.required_features.len);
                for (required_features, gop.value_ptr.required_features) |a, b|
                    std.debug.assert(std.mem.eql(u8, a, b));

                std.log.debug("known drv: {s}", .{drv_path});
            } else {
                gop.value_ptr.* = .{
                    .am_willing = am_willing,
                    .needed_system = needed_system,
                    .drv_path = drv_path,
                    .required_features = required_features,
                };

                const drv_json = try std.json.stringifyAlloc(allocator, gop.value_ptr.*, .{});
                defer allocator.free(drv_json);

                std.log.debug("new drv: {s}", .{drv_json});
            }

            break :blk gop.value_ptr;
        };

        try ifds_writer.writeAll(drv.drv_path);
        try ifds_writer.writeByte('\n');

        try decline();
    }

    // The rest of this function is only implemented to demonstrate
    // how a build hook would be expected to behave in principle.
    // In practice we will never get here
    // because we do not intend to accept any build.

    const accepted = try accept(allocator, "ssh://example.com");
    defer accepted.deinit(allocator);

    {
        const accepted_json = try std.json.stringifyAlloc(allocator, accepted, .{});
        defer allocator.free(accepted_json);

        std.log.debug("accepted: {s}", .{accepted_json});
    }
}

fn decline() !void {
    try stderr.print("# decline\n", .{});
}

/// The nix daemon will immediately kill the build hook after we decline permanently
/// so make sure to clean up all resources before calling this function.
///
/// This is because (if I interpret nix' code correctly)
/// [`worker.hook = 0`](https://github.com/NixOS/nix/blob/5fe2accb754249df6cb8f840330abfcf3bd26695/src/libstore/build/derivation-goal.cc#L1160)
/// invokes the [destructor](https://github.com/NixOS/nix/blob/5fe2accb754249df6cb8f840330abfcf3bd26695/src/libstore/build/hook-instance.cc#L82)
/// which sends SIGKILL [by default](https://github.com/NixOS/nix/blob/5fe2accb754249df6cb8f840330abfcf3bd26695/src/libutil/processes.cc#L54) (oof).
fn declinePermanently() !void {
    try stderr.print("# decline-permanently\n", .{});
}

fn postpone() !void {
    try stderr.print("# postpone\n", .{});
}

const Accepted = struct {
    inputs: []const []const u8,
    wanted_outputs: []const []const u8,

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        for (self.inputs) |input| alloc.free(input);
        alloc.free(self.inputs);

        for (self.wanted_outputs) |output| alloc.free(output);
        alloc.free(self.wanted_outputs);
    }
};

/// The nix daemon will close stdin and wait for EOF from the build hook.
/// Therefore we can only accept once.
/// The nix daemon will start another instance of the build hook for the remaining derivations.
fn accept(allocator: std.mem.Allocator, store_uri: []const u8) !Accepted {
    try stderr.print("# accept\n{s}\n", .{store_uri});

    const inputs = try protocol.readPackets(allocator, stdin);
    errdefer {
        for (inputs) |input| allocator.free(input);
        allocator.free(inputs);
    }

    const wanted_outputs = try protocol.readPackets(allocator, stdin);
    errdefer {
        for (wanted_outputs) |wanted_output| allocator.free(wanted_output);
        allocator.free(wanted_outputs);
    }

    return .{
        .inputs = inputs,
        .wanted_outputs = wanted_outputs,
    };
}

test {
    _ = log;
    _ = protocol;
}
