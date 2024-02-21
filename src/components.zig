const std = @import("std");
const trait = @import("trait");

const lib = @import("lib");
const wasm = lib.wasm;

const Runtime = @import("Runtime.zig");

pub const Http = @import("components/Http.zig");
pub const Nix = @import("components/Nix.zig");
pub const Process = @import("components/Process.zig");
pub const Timeout = @import("components/Timeout.zig");

pub const CallbackUnmanaged = struct {
    func_name: [:0]const u8,
    user_data: ?[]const u8,

    pub fn run(self: @This(), allocator: std.mem.Allocator, runtime: Runtime, inputs: []const wasm.Value, outputs: []wasm.Value) !bool {
        const linear = try runtime.linearMemoryAllocator();
        const linear_allocator = linear.allocator();

        const user_data = if (self.user_data) |user_data| try linear_allocator.dupe(u8, user_data) else null;
        defer if (user_data) |ud| linear_allocator.free(ud);

        var final_inputs = try allocator.alloc(wasm.Value, inputs.len + 2);
        defer allocator.free(final_inputs);

        final_inputs[0] = .{ .i32 = if (user_data) |ud| @intCast(linear.memory.offset(ud.ptr)) else 0 };
        final_inputs[1] = .{ .i32 = if (user_data) |ud| @intCast(ud.len) else 0 };
        for (final_inputs[2..], inputs) |*final_input, input| final_input.* = input;

        // TODO run on new thread
        const success = try runtime.call(self.func_name, final_inputs, outputs);
        if (!success) std.log.info("callback function \"{s}\" from plugin \"{s}\" finished unsuccessfully", .{ self.func_name, runtime.plugin_name });

        return success;
    }
};

pub const CallbackDoneCondition = union(enum) {
    always,
    on: struct {
        failure: bool = true,
        output0: ?bool = true,
    },

    pub fn check(self: @This(), success: bool, outputs: []const wasm.Value) bool {
        return switch (self) {
            .always => true,
            .on => |on| on.failure and !success or
                if (on.output0) |v| outputs[0].i32 == @intFromBool(v) else false,
        };
    }
};

pub fn rejectIfStopped(running: *const std.atomic.Value(bool)) error{ComponentStopped}!void {
    if (!running.load(.Monotonic)) return error.ComponentStopped;
}
