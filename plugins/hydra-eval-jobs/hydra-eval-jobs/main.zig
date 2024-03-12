const std = @import("std");
const args = @import("args");

pub fn main() !void {
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
        delay: u32 = 5 * std.time.ms_per_s,
        @"max-requests": u16 = 8 * std.time.s_per_hour / 5,

        pub const meta = .{
            .full_text = "A drop-in replacment for hydra-eval-jobs to evaluate using cizero",
            .option_docs = .{
                .@"gc-roots-dir" = "garbage collector roots directory (ignored, only for compatibility)",
                .@"dry-run" = "don't create store derivations (ignored, only for compatibility)",
                .flake = "build a flake (needed, non-flakes are not supported)",

                .@"max-jobs" = "passed through to nix (ignored, only for compatibility)",

                .url = "webhook endpoint URL of the cizero plugin",
                .delay = "duration in milliseconds to wait between requests while waiting for evaluation",
                .@"max-requests" = "maximum number of requests while waiting for evaluation",
            },
        };
    };
    const options = args.parseForCurrentProcess(Options, allocator, .print) catch |err| if (err == error.InvalidArguments) {
        try args.printHelp(Options, "hydra-eval-jobs FLAKE", std.io.getStdErr().writer());
        std.process.exit(1);
    } else return err;
    defer options.deinit();

    if (options.options.@"gc-roots-dir" != null) warnOptionIgnored("--gc-roots-dir");
    if (options.options.@"dry-run") warnOptionIgnored("--dry-run");
    if (!options.options.flake) {
        std.log.err("--flake is needed (support for non-flakes is not implemented)", .{});
        std.process.exit(1);
    }

    const flake = if (options.positionals.len != 1) {
        std.log.err("need exactly one positional argument, got {d}", .{options.positionals.len});
        std.process.exit(1);
    } else options.positionals[0];

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var client_arena = std.heap.ArenaAllocator.init(allocator);
    defer client_arena.deinit();

    try client.initDefaultProxies(client_arena.allocator());

    var request_count: u16 = 0;
    while (true) : (request_count += 1) {
        if (request_count > options.options.@"max-requests") {
            std.log.err("max request count ({d}) exceeded", .{options.options.@"max-requests"});
            std.process.exit(1);
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
                std.log.info("waiting for evaluation...", .{});
                std.log.debug("sending request in {d} ms", .{options.options.delay});

                std.time.sleep(@as(u64, options.options.delay) * std.time.ns_per_ms);
            },
            .ok => {
                std.log.info("evaluation successful", .{});

                try std.io.getStdOut().writeAll(response.items);
                std.process.cleanExit();
                return;
            },
            else => {
                std.log.info("evaluation failed", .{});

                try std.io.getStdErr().writeAll(response.items);
                std.process.exit(1);
            },
        }
    }
}

fn warnOptionIgnored(comptime option: []const u8) void {
    std.log.warn("ignoring " ++ option ++ " (just supported for compatibility)", .{});
}
