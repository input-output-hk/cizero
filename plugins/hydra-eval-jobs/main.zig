const std = @import("std");

const cizero = @import("cizero");

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

            const file_reader = file.reader();

            const file_contents = try file_reader.readAllAlloc(allocator, std.math.maxInt(usize));
            defer allocator.free(file_contents);

            const variant_separator_idx = std.mem.indexOfScalar(u8, file_contents, '\n').?;
            const variant_str = file_contents[0..variant_separator_idx];
            const variant = std.meta.stringToEnum(std.meta.Tag(cizero.nix.OnEvalResult), variant_str).?;

            const body = try allocator.dupeZ(u8, file_contents[variant_separator_idx + 1 ..]);
            errdefer allocator.free(body);

            return .{
                .status = if (variant == .ok) 200 else 422,
                .body = body,
            };
        } else |err| if (err != error.FileNotFound) return err;
    }

    const expr = expr: {
        const jobs_expr = "(" ++ @embedFile("jobs.nix") ++ ")";
        var expr = try std.ArrayListUnmanaged(u8).initCapacity(allocator, jobs_expr.len + 3);
        errdefer expr.deinit(allocator);
        expr.appendSliceAssumeCapacity(jobs_expr);
        expr.appendSliceAssumeCapacity(" \"");
        try expr.appendSlice(allocator, flake);
        expr.appendAssumeCapacity('"');

        break :expr try expr.toOwnedSliceSentinel(allocator, 0);
    };
    defer allocator.free(expr);

    if (cizero.nix.evalState(expr, .json) == null) try cizero.nix.onEval(
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
        expr,
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

    const file_writer = file.writer();

    try file_writer.writeAll(@tagName(result));
    try file_writer.writeByte('\n');

    switch (result) {
        .ok, .failed, .ifd_failed => |case| try file_writer.writeAll(case),
        .ifd_deps_failed => |case| {
            try file_writer.writeAll(case.ifd);
            try file_writer.writeByte('\n');
            for (case.drvs) |drv| {
                try file_writer.writeAll(drv);
                try file_writer.writeByte('\n');
            }
        },
        .ifd_too_deep => {},
    }
}
