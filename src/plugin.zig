const std = @import("std");

pub const Runtime = @import("plugin/Runtime.zig");

// TODO seems pretty unnecessary if this is only going to hold `wasm`?
pub const Plugin = struct {
    wasm: []const u8,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.wasm);
    }

    pub fn init(wasm: []const u8) @This() {
        return .{ .wasm = wasm };
    }

    /// Remember to deinit the runtime after use.
    pub fn runtime(self: *@This(), allocator: std.mem.Allocator, name: []const u8, host_functions: std.StringHashMapUnmanaged(Runtime.HostFunction)) !Runtime {
        return try Runtime.init(allocator, name, self.wasm, host_functions);
    }
};
