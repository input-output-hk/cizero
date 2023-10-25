const std = @import("std");

pub const Runtime = @import("plugin/Runtime.zig");

path: []const u8,

pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
    allocator.free(self.path);
}

pub fn name(self: @This()) []const u8 {
    return std.fs.path.stem(self.path);
}

pub fn wasm(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, self.path, std.math.maxInt(usize));
}
