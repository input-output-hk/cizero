const std = @import("std");

const plugin = @import("../plugin.zig");
const wasm = @import("../wasm.zig");

pub const name = "to_upper";

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(plugin.Runtime.HostFunctionDef) {
    var host_functions = std.StringArrayHashMapUnmanaged(plugin.Runtime.HostFunctionDef){};
    errdefer host_functions.deinit(allocator);
    try host_functions.ensureTotalCapacity(allocator, 1);

    host_functions.putAssumeCapacityNoClobber("toUpper", .{
        .signature = .{
            .params = &.{ .i32 },
            .returns = &.{},
        },
        .host_function = .{
            .callback = @ptrCast(&toUpper),
            .user_data = self,
        },
    });

    return host_functions;
}

fn toUpper(_: *@This(), _: []const u8, memory: []u8, inputs: []const wasm.Val, outputs: []wasm.Val) !void {
    std.debug.assert(inputs.len == 1);
    std.debug.assert(outputs.len == 0);

    const buf_ptr: [*c]u8 = &memory[@intCast(inputs[0].i32)];
    var buf = std.mem.span(buf_ptr);
    _ = std.ascii.upperString(buf, buf);
}
