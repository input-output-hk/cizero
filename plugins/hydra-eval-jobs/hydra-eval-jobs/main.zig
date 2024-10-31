const std = @import("std");
const args = @import("args");

const utils = @import("utils");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.page_allocator,
    };
    defer if (gpa.deinit() == .leak) std.log.err("leaked memory", .{});
    const allocator = gpa.allocator();

    const Options = struct {
        // needed for compatibility
        @"gc-roots-dir": ?[]const u8 = null,
        @"dry-run": bool = false,
        flake: bool = false,

        // The original hydra-eval-jobs ignores common nix options
        // so that its in-process nix evaluator can pick them up.
        // However, handling all nix options would be too much work,
        // so we just implement a subset that we know Hydra does pass.
        @"max-jobs": u16 = 0,

        url: []const u8 = "http://127.0.0.1:5882/webhook/hydra-eval-jobs",
        /// milliseconds
        interval: u32 = 5 * std.time.ms_per_s,
        @"max-requests": u16 = 8 * std.time.s_per_hour / 5,

        pub const meta = .{
            .full_text = "A drop-in replacment for hydra-eval-jobs to evaluate using cizero",
            .option_docs = .{
                .@"gc-roots-dir" = "garbage collector roots directory (ignored, only for compatibility)",
                .@"dry-run" = "don't create store derivations (ignored, only for compatibility)",
                .flake = "build a flake (needed, non-flakes are not supported)",

                .@"max-jobs" = "passed through to nix (ignored, only for compatibility)",

                .url = "webhook endpoint URL of the cizero plugin",
                .interval = "duration in milliseconds to wait between requests while waiting for evaluation",
                .@"max-requests" = "maximum number of requests while waiting for evaluation",
            },
        };
    };
    const options = args.parseForCurrentProcess(Options, allocator, .print) catch |err| if (err == error.InvalidArguments) {
        try args.printHelp(Options, "hydra-eval-jobs FLAKE", std.io.getStdErr().writer());
        return 1;
    } else return err;
    defer options.deinit();

    if (options.options.@"gc-roots-dir" != null) warnOptionIgnored("--gc-roots-dir");
    if (options.options.@"dry-run") warnOptionIgnored("--dry-run");
    if (!options.options.flake) {
        std.log.err("--flake is needed (support for non-flakes is not implemented)", .{});
        return 1;
    }

    const flake = if (options.positionals.len != 1) {
        std.log.err("need exactly one positional argument, got {d}", .{options.positionals.len});
        return 1;
    } else options.positionals[0];

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var client_arena = std.heap.ArenaAllocator.init(allocator);
    defer client_arena.deinit();

    try client.initDefaultProxies(client_arena.allocator());

    const is_tty = std.io.getStdErr().isTty();

    var request_count: u16 = 0;
    poll: while (true) : (request_count += 1) {
        if (request_count > options.options.@"max-requests") {
            std.log.err("max request count ({d}) exceeded", .{options.options.@"max-requests"});
            return 1;
        }

        var response = std.ArrayList(u8).init(allocator);
        defer response.deinit();

        std.log.debug("sending request to {s}", .{options.options.url});
        const result = try client.fetch(.{
            .location = .{ .url = options.options.url },
            .response_storage = .{ .dynamic = &response },
            .payload = flake,
        });

        switch (result.status) {
            .no_content => {
                if (std.log.defaultLogEnabled(.info) and request_count != 0) {
                    std.debug.lockStdErr();
                    defer std.debug.unlockStdErr();

                    const elapsed_s = request_count * options.options.interval / std.time.ms_per_s;

                    if (is_tty)
                        try std.io.getStdErr().writer().print(
                            "\rstill evaluating after {d} seconds…",
                            .{elapsed_s},
                        )
                    else {
                        if (request_count == 1)
                            try std.io.getStdErr().writer().writeAll("still evaluating after ");

                        try std.io.getStdErr().writer().print("{d}s… ", .{elapsed_s});
                    }
                }

                std.time.sleep(@as(u64, options.options.interval) * std.time.ns_per_ms);
            },
            else => |status| {
                if (std.log.defaultLogEnabled(.info) and request_count > 1) {
                    std.debug.lockStdErr();
                    defer std.debug.unlockStdErr();

                    try std.io.getStdErr().writer().writeByte('\n');
                }

                switch (status) {
                    .ok => {
                        std.log.info("evaluation successful", .{});

                        try std.io.getStdOut().writeAll(response.items);

                        break :poll;
                    },
                    .failed_dependency => {
                        std.log.info("evaluation could not finish due to failed IFD build", .{});

                        var stderr_buffered = std.io.bufferedWriter(std.io.getStdErr().writer());
                        const stderr = stderr_buffered.writer();

                        const failed_dependencies = try std.json.parseFromSlice(utils.nix.FailedBuilds, allocator, response.items, .{});
                        defer failed_dependencies.deinit();

                        if (failed_dependencies.value.dependents.len != 0)
                            std.log.info("IFD build failure prevented build of dependents {s}", .{failed_dependencies.value.dependents});

                        for (failed_dependencies.value.builds) |drv| {
                            const installable = try std.mem.concat(allocator, u8, &.{ drv, "^*" });
                            defer allocator.free(installable);

                            std.debug.lockStdErr();
                            defer std.debug.unlockStdErr();

                            try stderr.print("\nnix log {s}\n", .{installable});

                            var nix_log_process = std.process.Child.init(&.{ "nix", "log", installable }, allocator);
                            nix_log_process.stdin_behavior = .Close;
                            nix_log_process.stdout_behavior = .Pipe;
                            try nix_log_process.spawn();

                            {
                                var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4 * utils.mem.b_per_kib }).init();
                                defer fifo.deinit();

                                try fifo.pump(nix_log_process.stdout.?.reader(), stderr);
                            }

                            _ = try nix_log_process.wait();

                            try stderr.writeByte('\n');
                        }

                        try stderr_buffered.flush();

                        return 1;
                    },
                    else => |status_err| {
                        switch (status_err) {
                            .unprocessable_entity => std.log.info("evaluation failed", .{}),
                            else => std.log.info("evaluation failed due to unknown reason ({d}{s}{s})", .{
                                @intFromEnum(status_err),
                                if (status_err.phrase() != null) " " else "",
                                if (status_err.phrase()) |phrase| phrase else "",
                            }),
                        }

                        std.debug.lockStdErr();
                        defer std.debug.unlockStdErr();

                        try std.io.getStdErr().writeAll(response.items);

                        return 1;
                    },
                }
            },
        }
    }

    return 0;
}

fn warnOptionIgnored(comptime option: []const u8) void {
    std.log.warn("ignoring " ++ option ++ " (just supported for compatibility)", .{});
}
