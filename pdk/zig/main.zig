const std = @import("std");

const externs = struct {
    extern "cizero" fn toUpper([*c]u8) void;
    extern "cizero" fn onTimeout([*c]const u8, i64) void;
};

pub fn toUpper(alloc: std.mem.Allocator, lower: []const u8) ![]const u8 {
    var buf = try alloc.dupeZ(u8, lower);
    externs.toUpper(buf);
    return buf;
}

pub fn onTimeout(callback_func_name: [:0]const u8, timestamp_ms: i64) void {
    externs.onTimeout(callback_func_name, timestamp_ms);
}
