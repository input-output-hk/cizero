const std = @import("std");

const wasm = @import("../wasm.zig");

const Plugin = @import("../Plugin.zig");

pub const name = "to_upper";

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    var host_functions = std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef){};
    errdefer host_functions.deinit(allocator);
    try host_functions.ensureTotalCapacity(allocator, 1);

    host_functions.putAssumeCapacityNoClobber("toUpper", .{
        .signature = .{
            .params = &.{ .i32 },
            .returns = &.{},
        },
        .host_function = Plugin.Runtime.HostFunction.init(toUpper, self),
    });

    return host_functions;
}

fn toUpper(_: *@This(), _: Plugin, memory: []u8, inputs: []const wasm.Val, outputs: []wasm.Val) !void {
    std.debug.assert(inputs.len == 1);
    std.debug.assert(outputs.len == 0);

    const buf_ptr: [*c]u8 = &memory[@intCast(inputs[0].i32)];
    var buf = std.mem.span(buf_ptr);
    _ = std.ascii.upperString(buf, buf);
}
