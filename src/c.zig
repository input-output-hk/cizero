pub usingnamespace @cImport({
    @cInclude("wasmtime.h");
    @cInclude("sqlite3.h");
    @cInclude("whereami.h");
});

const std = @import("std");

const c = @This();

pub const whereami = struct {
    pub const ExecutablePath = struct {
        path: []const u8,
        dirname_len: usize,

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.path);
        }

        pub fn dir_path(self: @This()) []const u8 {
            return self.path[0..self.dirname_len];
        }

        pub fn exe_name(self: @This()) []const u8 {
            return self.path[self.dirname_len + 1 ..];
        }
    };

    pub fn getExecutablePath(allocator: std.mem.Allocator) !ExecutablePath {
        const len = c.wai_getExecutablePath(null, 0, null);

        const path = try allocator.alloc(u8, @intCast(len));
        errdefer allocator.free(path);

        var dirname_len: c_int = 0;

        std.debug.assert(c.wai_getExecutablePath(path.ptr, len, &dirname_len) == len);

        return .{ .path = path, .dirname_len = @intCast(dirname_len) };
    }
};
