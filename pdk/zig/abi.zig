const std = @import("std");
const trait = @import("trait");
const s2s = @import("s2s");

const lib = @import("lib");
const mem = lib.mem;
const meta = lib.meta;

pub const CallbackData = struct {
    /// type-erased function pointer
    /// (function pointers always have the same size)
    callback: *const anyopaque,
    user_data: []const u8,

    pub fn serialize(
        comptime UserData: type,
        allocator: std.mem.Allocator,
        callback: *const anyopaque,
        user_data_value: UserData.Value,
    ) std.mem.Allocator.Error![]const u8 {
        validateUserData(UserData);

        const user_data_value_bytes = try UserData.serialize(allocator, user_data_value);
        defer allocator.free(user_data_value_bytes);

        return std.mem.concat(allocator, u8, &.{
            std.mem.asBytes(&callback),
            user_data_value_bytes,
        });
    }

    pub fn deserialize(serialized: []const u8) @This() {
        const callback_size = @sizeOf(std.meta.fieldInfo(@This(), .callback).type);
        return .{
            .callback = @ptrFromInt(@as(usize, @bitCast(serialized[0..callback_size].*))),
            .user_data = serialized[callback_size..],
        };
    }

    pub fn call(self: @This(), Callback: fn (comptime UserData: type) type, args: anytype) @typeInfo(Callback(struct { []const u8 })).Fn.return_type.? {
        const callback: *const Callback(struct { []const u8 }) = @ptrCast(self.callback);
        return @call(.auto, callback, .{.{self.user_data}} ++ args);
    }

    pub fn validateUserData(comptime UserData: type) void {
        comptime {
            if (!trait.hasFn("serialize")(UserData)) @compileError(@typeName(UserData) ++ " must have a function `serialize(Allocator, Value) ![]const u8`");

            if (!@hasDecl(UserData, "Value")) @compileError(@typeName(UserData) ++ " must have a declaration `Value`");

            // This is because `UserData` is supposed to be a wrapper
            // around the serialized bytes with no additional fields.
            // Its only purpose could be to deserialize the slice,
            // and all type info for that is available at compile time,
            // so it does not increase the struct size.
            std.debug.assert(@sizeOf(struct { []const u8 }) == @sizeOf([]const u8));
            if (@sizeOf(UserData) != @sizeOf([]const u8)) @compileError(@typeName(UserData) ++ " must be same size as a slice");
        }
    }

    /// A collection of ready-made user data types.
    pub const user_data = struct {
        /// Serialization using s2s.
        pub fn S2S(comptime V: type) type {
            return struct {
                serialized: []const u8,

                pub const Value = V;

                pub fn serialize(allocator: std.mem.Allocator, value: Value) ![]const u8 {
                    var serialized = std.ArrayListUnmanaged(u8){};
                    errdefer serialized.deinit(allocator);

                    try s2s.serialize(serialized.writer(allocator), Value, value);

                    return serialized.toOwnedSlice(allocator);
                }

                pub fn deserialize(self: @This()) !Value {
                    var stream = std.io.fixedBufferStream(self.serialized);
                    return s2s.deserialize(stream.reader(), Value);
                }

                pub fn deserializeAlloc(self: @This(), allocator: std.mem.Allocator) !Value {
                    var stream = std.io.fixedBufferStream(self.serialized);
                    return s2s.deserializeAlloc(stream.reader(), Value, allocator);
                }

                pub fn free(allocator: std.mem.Allocator, value: *Value) void {
                    s2s.free(allocator, Value, value);
                }
            };
        }

        /// Shallow copy using `mem.anyAsBytesUnpad()`.
        pub fn Shallow(comptime V: type) type {
            return struct {
                serialized: []const u8,

                pub const Value = V;

                pub fn serialize(allocator: std.mem.Allocator, value: Value) ![]const u8 {
                    return allocator.dupe(u8, mem.anyAsBytesUnpad(&value));
                }

                const Self = @This();

                pub usingnamespace if (@sizeOf(Value) == 0) struct {} else struct {
                    pub fn deserialize(self: Self) Value {
                        return std.mem.bytesToValue(Value, self.serialized);
                    }
                };
            };
        }
    };

    test user_data {
        for (std.meta.fieldNames(user_data)) |field_name|
            validateUserData(@field(user_data, field_name)(void));
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
pub fn fixZeroLenSlice(slice: anytype) @TypeOf(slice) {
    const Slice = @TypeOf(slice);
    return if (slice.len == 0)
        @as([1]std.meta.Elem(Slice), undefined)[0..0]
    else
        slice;
}
