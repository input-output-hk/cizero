const std = @import("std");

pub usingnamespace @cImport({
    @cInclude("errno.h");

    @cInclude("wasmedge/wasmedge.h");

    @cInclude("util.h");
});

pub fn cstr(s: [*c]const u8) []const u8 {
    return s[0..std.mem.len(s)];
}

test cstr {
    const str = "abc";
    const strZ: [:0]const u8 = str;
    const strC: [*c]const u8 = @ptrCast(strZ);
    try std.testing.expectEqualStrings(str, cstr(strC));
}
