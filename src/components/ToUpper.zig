const std = @import("std");

const meta = @import("../meta.zig");
const wasm = @import("../wasm.zig");

const Plugin = @import("../Plugin.zig");

pub const name = "to_upper";

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    return meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef), allocator, .{
        .toUpper = Plugin.Runtime.HostFunctionDef{
            .signature = .{
                .params = &.{.i32},
                .returns = &.{},
            },
            .host_function = Plugin.Runtime.HostFunction.init(toUpper, self),
        },
    });
}

fn toUpper(_: *@This(), _: Plugin, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 1);
    std.debug.assert(outputs.len == 0);

    var buf = wasm.span(memory, inputs[0]);
    _ = std.ascii.upperString(buf, buf);
}
