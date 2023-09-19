const std = @import("std");

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
