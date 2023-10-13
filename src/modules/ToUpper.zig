const std = @import("std");

const wasm = @import("../wasm.zig");

const Plugin = @import("../Plugin.zig");

pub const name = "to_upper";

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    var host_functions = std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef){};
    errdefer host_functions.deinit(allocator);

    {
        const fns = .{
            .toUpper = Plugin.Runtime.HostFunctionDef{
                .signature = .{
                    .params = &.{.i32},
                    .returns = &.{},
                },
                .host_function = Plugin.Runtime.HostFunction.init(toUpper, self),
            },
        };
        const fields = @typeInfo(@TypeOf(fns)).Struct.fields;
        try host_functions.ensureTotalCapacity(allocator, fields.len);
        inline for (fields) |field|
            host_functions.putAssumeCapacityNoClobber(field.name, @field(fns, field.name));
    }

    return host_functions;
}

fn toUpper(_: *@This(), _: Plugin, memory: []u8, inputs: []const wasm.Val, outputs: []wasm.Val) !void {
    std.debug.assert(inputs.len == 1);
    std.debug.assert(outputs.len == 0);

    var buf = wasm.span(memory, inputs[0]);
    _ = std.ascii.upperString(buf, buf);
}
