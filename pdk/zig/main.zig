const std = @import("std");

const externs = struct {
    extern "cizero" fn add(i32, i32) i32;
    extern "cizero" fn toUpper([*c]u8) void;
    extern "cizero" fn yieldTimeout([*c]const u8, u64) noreturn;
};

pub const add = externs.add;

pub fn toUpper(alloc: std.mem.Allocator, lower: []const u8) ![]const u8 {
    var buf = try alloc.dupeZ(u8, lower);
    externs.toUpper(buf);
    return buf;
}

pub fn yieldTimeout(callback_func_name: [:0]const u8, timeout_ms: u64) noreturn {
    externs.yieldTimeout(callback_func_name, timeout_ms);
}
