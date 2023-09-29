const builtin = @import("builtin");
const std = @import("std");
const cizero = @import("cizero");

const allocator = std.heap.wasm_allocator;

usingnamespace if (builtin.is_test) struct {} else struct {
    export fn timeoutCallback() void {
        const now_s = @divFloor(std.time.milliTimestamp(), std.time.ms_per_s);
        std.debug.print("continued after timeout at {d}\n", .{now_s});
    }
};

pub fn main() u8 {
    return main2() catch |err| handleError(err);
}

fn main2() !u8 {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    while (args.next()) |arg| {
        const upper = try cizero.toUpper(allocator, arg);
        defer allocator.free(upper);

        std.debug.print("{s} → {s}\n", .{arg, upper});
    }

    const now_ms = std.time.milliTimestamp();
    const timeout_ms = now_ms + 2 * std.time.ms_per_s;
    std.debug.print("setting timeout callback for {d}s at {d}s\n", .{
        @divFloor(timeout_ms, std.time.ms_per_s),
        @divFloor(now_ms, std.time.ms_per_s),
    });
    cizero.onTimeout("timeoutCallback", timeout_ms);

    return 0;
}

fn handleError(err: anyerror) u8 {
    std.log.err("{any}\n", .{err});
    return 1;
}
