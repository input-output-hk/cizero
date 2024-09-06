const std = @import("std");
const s2s = @import("s2s");

const cizero = @import("cizero");

const lib = @import("lib");
const nix = lib.nix;

const allocator = std.heap.wasm_allocator;

pub fn main() u8 {
    cizero.http.onWebhook(cizero.user_data.Shallow(void), allocator, struct {
        fn callback(
            user_data: cizero.user_data.Shallow(void),
            flake: []const u8,
        ) cizero.http.OnWebhookCallbackResponse {
            return onWebhook(user_data, flake) catch |err| @panic(@errorName(err));
        }
    }.callback, {}) catch |err| @panic(@errorName(err));

    return 0;
}

fn onWebhook(
    _: cizero.user_data.Shallow(void),
    flake: []const u8,
) !cizero.http.OnWebhookCallbackResponse {
    std.log.info("got request for: {s}", .{flake});

    const file_name = try allocator.alloc(u8, std.fs.base64_encoder.calcSize(flake.len));
    defer allocator.free(file_name);

    std.debug.assert(std.fs.base64_encoder.encode(file_name, flake).len == file_name.len);

    {
        const cwd = std.fs.cwd();
        if (cwd.openFile(file_name, .{ .lock = .exclusive })) |file| {
            defer {
                file.close();
                cwd.deleteFile(file_name) catch |err| @panic(@errorName(err));
            }

            var result = try s2s.deserializeAlloc(file.reader(), cizero.nix.OnEvalResult, allocator);
            defer s2s.free(allocator, cizero.nix.OnEvalResult, &result);

            return .{
                .status = switch (result) {
                    .err => .internal_server_error,
                    .ok => |payload| switch (payload) {
                        .ok => .ok,
                        .failed, .ifd_failed => .unprocessable_entity,
                    },
                },
                .body = switch (result) {
                    .err => |name| try allocator.dupeZ(u8, name),
                    .ok => |payload| switch (payload) {
                        .ok, .failed => |case| try allocator.dupeZ(u8, case),
                        .ifd_failed => |ifd_failed| body: {
                            var body = std.ArrayList(u8).init(allocator);
                            errdefer body.deinit();

                            for (ifd_failed.builds, 1..) |ifd, len| {
                                try body.appendSlice(ifd);
                                if (len != ifd_failed.builds.len) try body.append(' ');
                            }
                            try body.append('\n');
                            for (ifd_failed.dependents, 1..) |dep, len| {
                                try body.appendSlice(dep);
                                if (len != ifd_failed.dependents.len) try body.append(' ');
                            }

                            break :body try body.toOwnedSliceSentinel(0);
                        },
                    },
                },
            };
        } else |err| if (err != error.FileNotFound) return err;
    }

    const flake_z = try allocator.dupeZ(u8, flake);
    defer allocator.free(flake_z);

    if (!cizero.nix.evalState(flake_z, &nix.hydraEvalJobs, .json)) try cizero.nix.onEval(
        cizero.user_data.Shallow([]const u8),
        allocator,
        struct {
            fn callback(
                name: cizero.user_data.Shallow([]const u8),
                result: cizero.nix.OnEvalResult,
            ) void {
                onEval(name, result) catch |err| @panic(@errorName(err));
            }
        }.callback,
        file_name,
        flake_z,
        &nix.hydraEvalJobs,
        .json,
    );

    return .{};
}

fn onEval(
    name: cizero.user_data.Shallow([]const u8),
    result: cizero.nix.OnEvalResult,
) !void {
    var file = try std.fs.cwd().createFile(name.deserialize(), .{ .exclusive = true });
    defer file.close();

    try s2s.serialize(file.writer(), cizero.nix.OnEvalResult, result);
}
