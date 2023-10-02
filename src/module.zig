const std = @import("std");

const plugin = @import("plugin.zig");
const wasm = @import("wasm.zig");

const Registry = @import("Registry.zig");

pub const Module = struct {
    impl: *anyopaque,
    impl_deinit: ?*const fn (*anyopaque) void,
    impl_host_functions: *const fn (*anyopaque, std.mem.Allocator) std.mem.Allocator.Error!std.StringArrayHashMapUnmanaged(plugin.Runtime.HostFunctionDef),

    name: []const u8,

    pub fn deinit(self: *@This()) void {
        if (self.impl_deinit) |f| f(self.impl);
    }

    pub fn init(impl: anytype) @This() {
        const Impl = std.meta.Child(@TypeOf(impl));
        return .{
            .impl = impl,
            .impl_deinit = if (comptime std.meta.trait.hasFn("deinit")(Impl)) @ptrCast(&Impl.deinit) else null,
            .impl_host_functions = @ptrCast(&Impl.hostFunctions),
            .name = Impl.name,
        };
    }

    /// The returned map's keys are expected to live at least as long as `impl`.
    /// Remember to deinit after use.
    pub fn hostFunctions(self: @This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(plugin.Runtime.HostFunctionDef) {
        return self.impl_host_functions(self.impl, allocator);
    }
};

pub const TimeoutModule = struct {
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

    fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(plugin.Runtime.HostFunctionDef) {
        var host_functions = std.StringArrayHashMapUnmanaged(plugin.Runtime.HostFunctionDef){};
        errdefer host_functions.deinit(allocator);
        try host_functions.ensureTotalCapacity(allocator, 1);

        host_functions.putAssumeCapacityNoClobber("onTimeout", .{
            .signature = .{
                .params = &.{ .i32, .i64 },
                .returns = &.{},
            },
            .host_function = .{
                .callback = @ptrCast(&onTimeout),
                .user_data = self,
            },
        });

        return host_functions;
    }

    fn onTimeout(self: *@This(), plugin_name: []const u8, memory: []u8, inputs: []const wasm.Val, outputs: []wasm.Val) !void {
        std.debug.assert(inputs.len == 2);
        std.debug.assert(outputs.len == 0);

        const state = blk: {
            const result = try self.plugin_states.getOrPut(self.allocator, plugin_name);
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
};

pub const ToUpperModule = struct {
    pub const name = "to_upper";

    // Ensure the type is not of size zero so that it can be pointed to by `Module`.
    _: u1 = undefined,

    fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(plugin.Runtime.HostFunctionDef) {
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
};
