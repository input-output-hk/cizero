const builtin = @import("builtin");
const std = @import("std");
const cizero = @import("cizero");

const allocator = std.heap.wasm_allocator;

usingnamespace if (builtin.is_test) struct {} else struct {
    export fn timestampCallback() void {
        const now_s = @divFloor(std.time.milliTimestamp(), std.time.ms_per_s);
        std.debug.print("> called timestampCallback() at {d}s\n", .{now_s});
    }

    export fn cronCallback() bool {
        const now_s = @divFloor(std.time.milliTimestamp(), std.time.ms_per_s);
        std.debug.print("> called cronCallback() at {d}s\n", .{now_s});
        return false;
    }
};

pub fn main() u8 {
    return mainZig() catch |err| {
        std.log.err("{}\n", .{err});
        return 1;
    };
}

fn mainZig() !u8 {
    {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        while (args.next()) |arg| {
            const upper = try cizero.toUpper(allocator, arg);
            defer allocator.free(upper);

            std.debug.print("> {s} → {s}\n", .{arg, upper});
        }
    }

    const now_ms = std.time.milliTimestamp();
    const now_s = try std.math.divFloor(i64, now_ms, std.time.ms_per_s);

    {
        const timeout_ms = now_ms + 2 * std.time.ms_per_s;
        std.debug.print("> calling onTimestamp({d}) at {d}s\n", .{
            try std.math.divFloor(i64, timeout_ms, std.time.ms_per_s),
            now_s,
        });
        cizero.onTimestamp("timestampCallback", timeout_ms);
    }

    {
        const cron = "* * * * *";
        std.debug.print("> calling onCron(\"{s}\") at {d}s\n", .{cron, now_s});
        const next = cizero.onCron("cronCallback", cron);
        std.debug.print(">> cronCallback() will be called at {d}s\n", .{
            try std.math.divFloor(i64, next, std.time.ms_per_s),
        });
    }

    {
        var env = std.process.EnvMap.init(allocator);
        try env.put("hey", "there");
        defer env.deinit();

        const result = cizero.exec(.{
            .allocator = allocator,
            .argv = &.{
                "sh", "-c",
                \\echo     this goes to stdout
                \\echo >&2 \$hey="$hey" goes to stderr
            },
            .env_map = &env,
        }) catch |err| {
            std.debug.print("> cizero.exec() failed: {}\n", .{err});
            return err;
        };

        std.debug.print("> term: {any}\n", .{result.term});
        std.debug.print("> stdout: {s}\n", .{result.stdout});
        std.debug.print("> stderr: {s}\n", .{result.stderr});
    }

    return 0;
}
