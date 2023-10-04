const std = @import("std");

const externs = struct {
    extern "cizero" fn toUpper([*c]u8) void;
    extern "cizero" fn onTimestamp([*c]const u8, i64) void;
    extern "cizero" fn onCron([*c]const u8, [*c]const u8) i64;
};

pub fn toUpper(alloc: std.mem.Allocator, lower: []const u8) ![]const u8 {
    var buf = try alloc.dupeZ(u8, lower);
    externs.toUpper(buf);
    return buf;
}

pub fn onTimestamp(callback_func_name: [:0]const u8, timestamp_ms: i64) void {
    externs.onTimestamp(callback_func_name, timestamp_ms);
}

pub fn onCron(callback_func_name: [:0]const u8, cron_expr: [:0]const u8) i64 {
    return externs.onCron(callback_func_name, cron_expr);
}
