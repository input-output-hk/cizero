const builtin = @import("builtin");
const std = @import("std");

const allocator = std.heap.wasm_allocator;

const cizero = struct {
    const ext = struct {
        extern "cizero" fn add(i32, i32) i32;
        extern "cizero" fn toUpper([*c]u8) void;
    };

    pub const add = ext.add;

    pub fn toUpper(alloc: std.mem.Allocator, lower: []const u8) ![]const u8 {
        var buf = try alloc.dupeZ(u8, lower);
        ext.toUpper(buf);
        return buf;
    }
};

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
