const builtin = @import("builtin");
const std = @import("std");
const cizero = @import("cizero");

const allocator = std.heap.wasm_allocator;

usingnamespace if (builtin.is_test) struct {} else struct {
    export fn fib(n: i32) i32 {
        if (n < 2) return 1;
        return cizero.add(fib(n - 2), fib(n - 1));
    }
};

pub fn main() u8 {
    var args = std.process.argsWithAllocator(allocator) catch unreachable;
    defer args.deinit();

    while (args.next()) |arg| {
        const upper = cizero.toUpper(allocator, arg) catch unreachable;
        defer allocator.free(upper);

        std.io.getStdOut().writer().print("{s} → {s}\n", .{arg, upper}) catch unreachable;
    }

    return 2;
}
