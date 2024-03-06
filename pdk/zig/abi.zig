const std = @import("std");
const trait = @import("trait");

const lib = @import("lib");
const mem = lib.mem;

pub const CallbackData = struct {
    /// type-erased function pointer
    /// (function pointers always have the same size)
    callback: *const anyopaque,
    user_data_is_slice: bool,
    user_data: []const u8,

    pub fn init(comptime UserData: type, callback: *const anyopaque, user_data: UserDataPtr(UserData)) @This() {
        return .{
            .callback = callback,
            .user_data_is_slice = comptime trait.ptrOfSize(.Slice)(@TypeOf(user_data)),
            .user_data = fixZeroLenSlice(u8, mem.anyAsBytesUnpad(user_data)),
        };
    }

    pub fn serialize(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        const callback_bytes = std.mem.asBytes(&self.callback);
        const user_data_is_slice_bytes = std.mem.asBytes(&self.user_data_is_slice);

        const serialized = try allocator.alloc(u8, callback_bytes.len + user_data_is_slice_bytes.len + self.user_data.len);
        errdefer allocator.free(serialized);

        @memcpy(serialized[0..callback_bytes.len], callback_bytes);
        @memcpy(serialized[callback_bytes.len .. callback_bytes.len + user_data_is_slice_bytes.len], user_data_is_slice_bytes);
        @memcpy(serialized[callback_bytes.len + user_data_is_slice_bytes.len ..], self.user_data);

        return serialized;
    }

    pub fn deserialize(serialized: []const u8) @This() {
        const callback_size = @sizeOf(std.meta.fieldInfo(@This(), .callback).type);

        const user_data_is_slice_size = @sizeOf(std.meta.fieldInfo(@This(), .user_data_is_slice).type);
        std.debug.assert(user_data_is_slice_size == 1);

        return .{
            .callback = @ptrFromInt(@as(usize, @bitCast(serialized[0..callback_size].*))),
            .user_data_is_slice = serialized[callback_size] == 1,
            .user_data = serialized[callback_size + user_data_is_slice_size ..],
        };
    }

    pub fn call(self: @This(), T: fn (type) type, args: anytype) @typeInfo(T(void)).Fn.return_type.? {
        if (self.user_data_is_slice) {
            const callback: *const T([]const u8) = @ptrCast(self.callback);
            return @call(.auto, callback, .{self.user_data} ++ args);
        } else {
            const callback: *const T(anyopaque) = @ptrCast(self.callback);
            return @call(.auto, callback, .{@as(*const anyopaque, @ptrCast(self.user_data.ptr))} ++ args);
        }
    }

    pub fn UserDataPtr(comptime UserData: type) type {
        return switch (@typeInfo(UserData)) {
            .Null => @compileError("null is awkward as user data type, use void instead"),
            .Pointer => |pointer| if (pointer.size == .Slice) UserData else @compileError(@tagName(pointer.size) ++ " pointers are not supported"),
            else => *const UserData,
        };
    }
};

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
