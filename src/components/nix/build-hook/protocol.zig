const std = @import("std");

pub const block_len = 8;

/// Returns the number of padding bytes.
pub fn padding(len: usize) std.math.IntFittingRange(0, block_len) {
    return if (len % block_len == 0) 0 else @intCast(block_len - len % block_len);
}

test padding {
    const Padding = @typeInfo(@TypeOf(padding)).Fn.return_type.?;
    try std.testing.expectEqual(@as(Padding, 0), padding(0));
    try std.testing.expectEqual(@as(Padding, 3), padding(5));
    try std.testing.expectEqual(@as(Padding, 0), padding(24));
}

/// Reads the padding for the given length and asserts it is all zeroes.
pub fn readPadding(reader: anytype, len: usize) !void {
    const padding_len = padding(len);
    if (padding_len == 0) return;

    var padding_buf: [block_len]u8 = undefined;
    var padding_slice = padding_buf[0..padding_len];
    if (try reader.readAll(padding_slice) < padding_slice.len) return error.EndOfStream;

    if (!std.mem.allEqual(u8, padding_slice, 0)) return error.BadPadding;
}

test readPadding {
    {
        const len = 5;
        var stream = std.io.fixedBufferStream(&([_]u8{0} ** padding(len)));
        try readPadding(stream.reader(), len);

        try std.testing.expectError(error.EndOfStream, stream.reader().readByte());
    }

    {
        var stream = std.io.fixedBufferStream(&[_]u8{ 0, 0, 1 });

        try std.testing.expectError(error.BadPadding, readPadding(stream.reader(), 5));
    }
}

/// Fills the buffer and discards the padding.
pub fn readPadded(reader: anytype, buf: []u8) !void {
    if (try reader.readAll(buf) < buf.len) return error.EndOfStream;
    try readPadding(reader, buf.len);
}

test readPadded {
    const input: []const u8 = &.{ 0, 1, 2, 3, 4, 0, 0, 0, 8, 9 };
    var stream = std.io.fixedBufferStream(input);

    var packet: [5]u8 = undefined;
    try readPadded(stream.reader(), &packet);

    try std.testing.expectEqualStrings(input[0..packet.len], &packet);

    {
        var buf: [input.len - block_len]u8 = undefined;
        try std.testing.expectEqual(buf.len, try stream.reader().readAll(&buf));
        try std.testing.expectEqualSlices(u8, input[block_len..], &buf);
    }
}

pub fn readU64(reader: anytype) !u64 {
    return reader.readIntLittle(u64);
}

pub fn readBool(reader: anytype) !bool {
    return switch (try readU64(reader)) {
        0 => false,
        1 => true,
        else => error.BadBool,
    };
}

pub fn readPacket(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
    var buf = try allocator.alloc(u8, try readU64(reader));
    errdefer allocator.free(buf);
    try readPadded(reader, buf);
    return buf;
}

pub fn readPackets(allocator: std.mem.Allocator, reader: anytype) ![][]u8 {
    var bufs = try allocator.alloc([]u8, try readU64(reader));
    errdefer {
        for (bufs) |buf| allocator.free(buf);
        allocator.free(bufs);
    }
    for (bufs) |*buf| buf.* = try readPacket(allocator, reader);
    return bufs;
}

const StringStringMapOwned = struct {
    map: std.StringHashMapUnmanaged([]u8) = .{},

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.map.deinit(alloc);
    }
};

pub fn readStringStringMap(allocator: std.mem.Allocator, reader: anytype) !StringStringMapOwned {
    var map = StringStringMapOwned{};
    errdefer map.deinit(allocator);
    while (try readU64(reader) != 0) {
        const key = try readPacket(allocator, reader);
        errdefer allocator.free(key);
        const value = try readPacket(allocator, reader);
        errdefer allocator.free(value);
        try map.map.put(allocator, key, value);
    }
    return map;
}
