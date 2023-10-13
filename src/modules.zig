const std = @import("std");

const wasm = @import("wasm.zig");

pub const Process = @import("modules/Process.zig");
pub const Timeout = @import("modules/Timeout.zig");
pub const ToUpper = @import("modules/ToUpper.zig");

pub fn CallbackUnmanaged(comptime T: type) type {
    return struct {
        func_name: [:0]const u8,
        condition: T,

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.func_name);
        }

        pub fn init(allocator: std.mem.Allocator, func_name: []const u8, condition: T) !@This() {
            return .{
                .func_name = try allocator.dupeZ(u8, func_name),
                .condition = condition,
            };
        }

        pub fn done(self: @This()) CallbackDoneCondition {
            return self.condition.done();
        }
    };
}

pub const CallbackDoneCondition = union(enum) {
    always,
    on: struct {
        failure: bool = true,
        output0: ?bool = true,
    },

    pub fn check(self: @This(), success: bool, outputs: []const wasm.Val) bool {
        return switch (self) {
            .always => true,
            .on => |on|
                on.failure and !success or
                if (on.output0) |v| outputs[0].i32 == @intFromBool(v) else false,
        };
    }
};

test {
    _ = std.testing.refAllDecls(@This());
}
