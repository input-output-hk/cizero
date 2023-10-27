const builtin = @import("builtin");
const std = @import("std");
const cizero = @import("cizero");

const allocator = std.heap.wasm_allocator;

usingnamespace if (builtin.is_test) struct {} else struct {
    export fn timestampCallback(user_data: *const i64, user_data_len: usize) void {
        std.debug.assert(user_data_len == @sizeOf(i64));

        const now_s = @divFloor(std.time.milliTimestamp(), std.time.ms_per_s);

        std.debug.print("> called {s}() at {d}s from {d}s\n", .{ @src().fn_name, now_s, user_data.* });
    }

    export fn cronCallback(user_data: *const i64, user_data_len: usize) bool {
        std.debug.assert(user_data_len == @sizeOf(i64));

        const now_s = @divFloor(std.time.milliTimestamp(), std.time.ms_per_s);

        std.debug.print("> called {s}() at {d}s from {d}s\n", .{ @src().fn_name, now_s, user_data.* });

        return false;
    }

    export fn webhookCallbackStr(user_data_ptr: ?[*]const u8, user_data_len: usize, body_ptr: [*:0]const u8) bool {
        const user_data: []const u8 = blk: {
            const default = "(none)";
            const ptr = user_data_ptr orelse default.ptr;
            const len = if (user_data_ptr) |_| user_data_len else default.len;
            break :blk ptr[0..len];
        };

        const body = std.mem.span(body_ptr);

        std.debug.print("> called {s}() with body {s} and user data {s}\n", .{ @src().fn_name, body, user_data });

        return false;
    }

    export fn webhookCallbackFoo(user_data: ?*const Foo, user_data_len: usize, body_ptr: [*:0]const u8) bool {
        std.debug.assert(user_data_len == @sizeOf(Foo));

        const body = std.mem.span(body_ptr);

        std.debug.print("> called {s}() with body {s} and user data {any}\n", .{ @src().fn_name, body, user_data });

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

            std.debug.print("> {s} → {s}\n", .{ arg, upper });
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
        cizero.onTimestamp("timestampCallback", now_s, timeout_ms);
    }

    {
        const cron = "* * * * *";
        std.debug.print("> calling onCron(\"{s}\") at {d}s\n", .{ cron, now_s });
        const next = cizero.onCron("cronCallback", now_s, cron);
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
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        std.debug.print("> term: {any}\n", .{result.term});
        std.debug.print("> stdout: {s}\n", .{result.stdout});
        std.debug.print("> stderr: {s}\n", .{result.stderr});
    }

    {
        cizero.onWebhook("webhookCallbackStr", "user data");
        cizero.onWebhook("webhookCallbackFoo", Foo{
            .a = 25,
            .b = .{ 372, 457 },
        });
    }

    return 0;
}

const Foo = struct {
    a: u8,
    b: [2]u16,
};
