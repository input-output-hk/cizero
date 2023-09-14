const std = @import("std");

const allocator = std.heap.wasm_allocator;

const cizero = struct {
    const ext = struct {
        extern "cizero" fn add(i32, i32) i32;
        extern "cizero" fn toUpper(usize, usize) usize;
    };

    pub const add = ext.add;

    pub fn toUpper(alloc: std.mem.Allocator, lower: []const u8) ![]const u8 {
        var upper_buf = try alloc.alloc(u8, lower.len);
        const upper_len = ext.toUpper(
            @intFromPtr(lower.ptr),
            @intFromPtr(upper_buf.ptr),
        );
        return upper_buf[0..upper_len];
    }
};

export fn fib(n: i32) i32 {
    if (n < 2) return 1;
    return cizero.add(fib(n - 2), fib(n - 1));
}

fn mainToUpper() !void {
    var args = std.process.argsWithAllocator(allocator) catch unreachable;
    defer args.deinit();

    while (args.next()) |arg| {
        const upper = try cizero.toUpper(allocator, arg);
        defer allocator.free(upper);

        try std.io.getStdOut().writer().print("{s} → {s} ({d})\n", .{arg, upper, upper.len});
    }
}

pub export fn main() u8 {
    mainToUpper() catch |err| std.debug.panic("{}\n", .{err});

    const exit_code = 2;
    std.process.exit(exit_code);
    return exit_code;
}
