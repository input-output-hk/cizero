const std = @import("std");

pub const CStringArray = struct {
    allocator: std.mem.Allocator,

    z: ?[]const [:0]const u8,
    c: []const [*:0]const u8,

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.c);

        if (self.z) |z| {
            for (z) |ze| self.allocator.free(ze);
            self.allocator.free(z);
        }
    }

    pub fn initDupe(allocator: std.mem.Allocator, array: []const []const u8) !@This() {
        const z = try allocator.alloc([:0]const u8, array.len);
        errdefer {
            for (z) |zz| allocator.free(zz);
            allocator.free(z);
        }
        for (z, array) |*ze, e| ze.* = try allocator.dupeZ(u8, e);

        var self = try initRef(allocator, z);
        self.z = z;

        return self;
    }

    pub fn initRef(allocator: std.mem.Allocator, z: []const [:0]const u8) !@This() {
        const c = try allocator.alloc([*:0]const u8, z.len);
        errdefer allocator.free(c);
        for (c, z) |*ce, ze| ce.* = ze.ptr;

        return .{ .allocator = allocator, .z = null, .c = c };
    }

    pub fn initStringStringMap(allocator: std.mem.Allocator, map: anytype) !@This() {
        const z = try allocator.alloc([:0]const u8, map.count() * 2);
        errdefer {
            for (z) |k_or_v| allocator.free(k_or_v);
            allocator.free(z);
        }

        var iter = map.iterator();
        var i: usize = 0;
        while (iter.next()) |kv| {
            defer i += 2;
            z[i] = try allocator.dupeZ(u8, kv.key_ptr.*);
            z[i + 1] = try allocator.dupeZ(u8, kv.value_ptr.*);
        }

        var self = try initRef(allocator, z);
        self.z = z;

        return self;
    }
};

// For some reason the pointer of a slice of a zero-length array
// becomes negative when received by cizero.
pub fn fixZeroLenSlice(comptime T: type, slice: []const T) []const T {
    return if (slice.len == 0)
        @as([1]T, undefined)[0..0]
    else
        slice;
}
