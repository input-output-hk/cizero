const builtin = @import("builtin");
const std = @import("std");
const cizero = @import("cizero");

const allocator = std.heap.wasm_allocator;

usingnamespace if (builtin.is_test) struct {} else struct {
    export fn timeoutCallback() void {
        std.debug.print("continued after timeout!\n", .{});
    }
};

fn fib(n: i32) i32 {
    if (n < 2) return 1;
    return cizero.add(fib(n - 2), fib(n - 1));
}

pub fn main() noreturn {
    var args = std.process.argsWithAllocator(allocator) catch unreachable;
    defer args.deinit();

    while (args.next()) |arg| {
        const upper = cizero.toUpper(allocator, arg) catch unreachable;
        defer allocator.free(upper);

        std.debug.print("{s} → {s}\n", .{arg, upper});
    }

    std.debug.print("fib({d}) = {d}\n", .{12, fib(12)});

    const timeout_ms = 1000 * 2;
    std.debug.print("yielding timeout of {d} ms…\n", .{timeout_ms});
    cizero.yieldTimeout("timeoutCallback", timeout_ms);
}
