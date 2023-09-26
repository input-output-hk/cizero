const std = @import("std");

const plugin = @import("plugin.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const plugin_wasm = try std.fs.cwd().readFileAlloc(allocator, args[1], std.math.maxInt(usize));
    defer allocator.free(plugin_wasm);

    var plugin_state = plugin.State.init(allocator);
    defer plugin_state.deinit();

    {
        const plugin_runtime = try plugin.Runtime.init(allocator, plugin_wasm, &plugin_state);
        defer plugin_runtime.deinit();

        try std.testing.expectEqual(plugin.Runtime.ExitStatus.yield, try plugin_runtime.main());
        try std.testing.expect(plugin_state.callback != null);
        try std.testing.expectEqualDeep(plugin.State.Callback{
            .func_name = "timeoutCallback",
            .condition = .{ .timeout_ms = 2000 },
        }, plugin_state.callback.?);
        try std.testing.expectEqual(@as(@TypeOf(plugin_state.kv).Size, 0), plugin_state.kv.count());
    }

    {
        const plugin_runtime = try plugin.Runtime.init(allocator, plugin_wasm, &plugin_state);
        defer plugin_runtime.deinit();

        try std.testing.expectEqual(plugin.Runtime.ExitStatus.success, try plugin_runtime.handleEvent(.timeout_ms));
    }
}

test {
    _ = plugin;
}
