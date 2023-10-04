const std = @import("std");

const wasm = @import("../wasm.zig");

const Plugin = @import("../Plugin.zig");
const Registry = @import("../Registry.zig");

pub const name = "timeout";

const Callback = struct {
    /// Milliseconds since the unix epoch.
    timestamp: i64,
    func_name: [:0]const u8,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.func_name);
    }

    pub fn init(allocator: std.mem.Allocator, timestamp: i64, func_name: []const u8) !@This() {
        return .{
            .timestamp = timestamp,
            .func_name = try allocator.dupeZ(u8, func_name),
        };
    }
};
const State = std.ArrayListUnmanaged(Callback);

registry: *Registry,

allocator: std.mem.Allocator,

plugin_states: std.StringHashMapUnmanaged(State) = .{},

restart_loop: std.Thread.ResetEvent = .{},

pub fn deinit(self: *@This()) void {
    {
        var plugin_state_iter = self.plugin_states.valueIterator();
        while (plugin_state_iter.next()) |state| {
            for (state.items) |callback| callback.deinit(self.allocator);
            state.deinit(self.allocator);
        }
    }

    self.plugin_states.deinit(self.allocator);
}

pub fn init(allocator: std.mem.Allocator, registry: *Registry) @This() {
    return .{
        .allocator = allocator,
        .registry = registry,
    };
}

pub fn start(self: *@This()) !std.Thread {
    return std.Thread.spawn(.{}, loop, .{ self });
}

fn loop(self: *@This()) noreturn {
    while (true) {
        const PluginCallback = struct {
            plugin_name: []const u8,
            callback: Callback,
            state_index: usize,
        };

        // TODO make thread safe
        const next_callback = blk: {
            var next: ?PluginCallback = null;

            // TODO use `std.sort` instead?
            var plugin_states_iter = self.plugin_states.iterator();
            while (plugin_states_iter.next()) |entry| {
                for (entry.value_ptr.items, 0..) |callback, i| {
                    if (next == null or callback.timestamp < next.?.callback.timestamp) next = .{
                        .plugin_name = entry.key_ptr.*,
                        .callback = callback,
                        .state_index = i,
                    };
                }
            }

            break :blk next;
        };

        if (next_callback) |next| {
            const now_ms = std.time.milliTimestamp();
            if (now_ms < next.callback.timestamp) {
                const timeout_ns: u64 = @intCast((next.callback.timestamp - now_ms) * std.time.ns_per_ms);
                self.restart_loop.timedWait(timeout_ns) catch
                    self.runCallback(next.plugin_name, next.callback, next.state_index);
            } else {
                self.runCallback(next.plugin_name, next.callback, next.state_index);
            }
        } else self.restart_loop.wait();

        self.restart_loop.reset();
    }
}

fn runCallback(self: *@This(), plugin_name: []const u8, callback: Callback, state_index: usize) void {
    _ = self.plugin_states.getPtr(plugin_name).?.swapRemove(state_index);

    // TODO run on new thread
    const runtime = self.registry.runtime(plugin_name) catch |err|
        std.debug.panic("failed to create runtime for plugin \"{s}\": {}", .{plugin_name, err});
    const success = runtime.call(callback.func_name, &.{}, &.{}) catch |err|
        std.debug.panic("failed to run callback function \"{s}\" on plugin \"{s}\": {}", .{callback.func_name, plugin_name, err});
    if (!success) std.log.info("callback function \"{s}\" on plugin \"{s}\" finished unsuccessfully", .{callback.func_name, plugin_name});
}

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    var host_functions = std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef){};
    errdefer host_functions.deinit(allocator);
    try host_functions.ensureTotalCapacity(allocator, 1);

    host_functions.putAssumeCapacityNoClobber("onTimeout", .{
        .signature = .{
            .params = &.{ .i32, .i64 },
            .returns = &.{},
        },
        .host_function = Plugin.Runtime.HostFunction.init(onTimeout, self),
    });

    return host_functions;
}

fn onTimeout(self: *@This(), plugin: Plugin, memory: []u8, inputs: []const wasm.Val, outputs: []wasm.Val) !void {
    std.debug.assert(inputs.len == 2);
    std.debug.assert(outputs.len == 0);

    const state = blk: {
        const result = try self.plugin_states.getOrPut(self.allocator, plugin.name());
        if (!result.found_existing) result.value_ptr.* = .{};
        break :blk result.value_ptr;
    };

    try state.append(self.allocator, try Callback.init(
        self.allocator,
        inputs[1].i64,
        std.mem.span(@as(
            [*c]const u8,
            &memory[@intCast(inputs[0].i32)],
        )),
    ));

    self.restart_loop.set();
}
