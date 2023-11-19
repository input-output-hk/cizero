const std = @import("std");

const log = @import("log.zig");
const protocol = @import("protocol.zig");

const stdin = std.io.getStdIn().reader();
const stderr = std.io.getStdErr().writer();

pub const std_options = struct {
    pub const logFn = log.logFn;
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

// Translated from `src/build-remote/build-remote.cc`.
fn innerMain(allocator: std.mem.Allocator) !void {
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

        std.log.debug("received nix config: \n{s}", .{settings_msg.items});
    }

    while (true) {
        {
            const command = protocol.readPacket(allocator, stdin) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            defer allocator.free(command);

            if (!std.mem.eql(u8, command, "try")) {
                std.log.debug("received unexpected command \"{s}\", expected \"try\"", .{std.fmt.fmtSliceEscapeLower(command)});
                return;
            }
        }

        const am_willing = try protocol.readBool(stdin);
        std.log.debug("am_willing: {}", .{am_willing});

        const needed_system = try protocol.readPacket(allocator, stdin);
        defer allocator.free(needed_system);
        std.log.debug("needed_system: {s}", .{needed_system});

        const drv_path = try protocol.readPacket(allocator, stdin);
        defer allocator.free(drv_path);
        std.log.debug("drv_path: {s}", .{drv_path});

        const required_features = try protocol.readPackets(allocator, stdin);
        defer {
            for (required_features) |feature| allocator.free(feature);
            allocator.free(required_features);
        }
        std.log.debug("required_features: {s}", .{required_features});

        const accepted = try accept(allocator, "ssh://example.com");
        defer accepted.deinit(allocator);
        std.log.debug(
            \\inputs: {s}
            \\wanted_outputs: {s}
        , .{ accepted.inputs, accepted.wanted_outputs });
    }
}

fn decline() !void {
    try stderr.print("# decline\n", .{});
}

fn declinePermanently() !void {
    try stderr.print("# decline-permanently\n", .{});
}

fn postpone() !void {
    try stderr.print("# postpone\n", .{});
}

fn accept(allocator: std.mem.Allocator, store_uri: []const u8) !struct {
    inputs: [][]u8,
    wanted_outputs: [][]u8,

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        for (self.inputs) |input| alloc.free(input);
        alloc.free(self.inputs);

        for (self.wanted_outputs) |output| alloc.free(output);
        alloc.free(self.wanted_outputs);
    }
} {
    try stderr.print("# accept\n{s}\n", .{store_uri});
    return .{
        .inputs = try protocol.readPackets(allocator, stdin),
        .wanted_outputs = try protocol.readPackets(allocator, stdin),
    };
}

test {
    _ = log;
    _ = protocol;
}
