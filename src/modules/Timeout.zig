const std = @import("std");

const Cron = @import("cron").Cron;
const Datetime = @import("datetime").datetime.Datetime;

const modules = @import("../modules.zig");
const wasm = @import("../wasm.zig");

const Plugin = @import("../Plugin.zig");
const Registry = @import("../Registry.zig");

pub const name = "timeout";

const Callback = struct {
    timeout: Timeout,
    func_name: [:0]const u8,

    pub const Timeout = union(enum) {
        /// Milliseconds since the unix epoch.
        timestamp: i64,
        cron: Cron,

        pub fn next(self: @This(), now_ms: i64) !i64 {
            return switch (self) {
                .timestamp => |ms| ms,
                .cron => |cron| blk: {
                    // XXX We need a mutable copy of `cron` because `Cron.next()` takes itself by pointer.
                    // It seems that is unnecessary though. Fix upstream?
                    var c = cron;
                    break :blk @intCast((try c.next(Datetime.fromTimestamp(now_ms))).toTimestamp());
                },
            };
        }
    };

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.func_name);
    }

    pub fn init(allocator: std.mem.Allocator, timeout: Timeout, func_name: []const u8) !@This() {
        return .{
            .timeout = timeout,
            .func_name = try allocator.dupeZ(u8, func_name),
        };
    }

    pub fn done(self: @This()) modules.CallbackDoneCondition {
        return switch (self.timeout) {
            .timestamp => .always,
            .cron => .{ .on = .{} },
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
    return std.Thread.spawn(.{}, loop, .{self});
}

fn loop(self: *@This()) !void {
    while (true) {
        const PluginCallback = struct {
            plugin_name: []const u8,
            callback: Callback,
            state_index: usize,
        };

        const now_ms = std.time.milliTimestamp();

        const next_callback = blk: {
            var next: ?PluginCallback = null;

            var plugin_states_iter = self.plugin_states.iterator();
            while (plugin_states_iter.next()) |entry| {
                for (entry.value_ptr.items, 0..) |callback, i| {
                    // XXX do not compute `callback.timeout.next()` multiple times
                    // XXX do not compute `next.?.callback.timeout.next()` multiple times
                    if (next == null or try callback.timeout.next(now_ms) < try next.?.callback.timeout.next(now_ms)) next = .{
                        .plugin_name = entry.key_ptr.*,
                        .callback = callback,
                        .state_index = i,
                    };
                }
            }

            break :blk next;
        };

        if (next_callback) |next| {
            const next_timestamp = try next.callback.timeout.next(now_ms);
            if (now_ms < next_timestamp) {
                const timeout_ns: u64 = @intCast((next_timestamp - now_ms) * std.time.ns_per_ms);
                self.restart_loop.timedWait(timeout_ns) catch
                    try self.runCallback(next.plugin_name, next.callback, next.state_index);
            } else {
                try self.runCallback(next.plugin_name, next.callback, next.state_index);
            }
        } else self.restart_loop.wait();

        self.restart_loop.reset();
    }
}

fn runCallback(self: *@This(), plugin_name: []const u8, callback: Callback, state_index: usize) !void {
    const runtime = try self.registry.runtime(plugin_name);

    // No need to heap-allocate here.
    // Just stack-allocate sufficient memory for all cases.
    var outputs_memory: [1]wasm.Val = undefined;
    var outputs = outputs_memory[0..switch (callback.timeout) {
        .timestamp => 0,
        .cron => 1,
    }];

    // TODO run on new thread
    const success = try runtime.call(callback.func_name, &.{}, outputs);
    if (!success) std.log.info("callback function \"{s}\" on plugin \"{s}\" finished unsuccessfully", .{ callback.func_name, plugin_name });

    if (callback.done().check(success, outputs)) {
        var state = self.plugin_states.getPtr(plugin_name).?;
        _ = state.swapRemove(state_index);
    }
}

fn addCallback(self: *@This(), plugin_name: []const u8, callback: Callback) !void {
    const state = blk: {
        const result = try self.plugin_states.getOrPut(self.allocator, plugin_name);
        if (!result.found_existing) result.value_ptr.* = .{};
        break :blk result.value_ptr;
    };

    try state.append(self.allocator, callback);
}

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    var host_functions = std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef){};
    errdefer host_functions.deinit(allocator);
    try host_functions.ensureTotalCapacity(allocator, 1);

    host_functions.putAssumeCapacityNoClobber("onTimestamp", .{
        .signature = .{
            .params = &.{ .i32, .i64 },
            .returns = &.{},
        },
        .host_function = Plugin.Runtime.HostFunction.init(onTimestamp, self),
    });
    host_functions.putAssumeCapacityNoClobber("onCron", .{
        .signature = .{
            .params = &.{ .i32, .i32 },
            .returns = &.{.i64},
        },
        .host_function = Plugin.Runtime.HostFunction.init(onCron, self),
    });

    return host_functions;
}

fn onTimestamp(self: *@This(), plugin: Plugin, memory: []u8, inputs: []const wasm.Val, outputs: []wasm.Val) !void {
    std.debug.assert(inputs.len == 2);
    std.debug.assert(outputs.len == 0);

    try self.addCallback(plugin.name(), try Callback.init(
        self.allocator,
        .{ .timestamp = inputs[1].i64 },
        wasm.span(memory, inputs[0]),
    ));

    self.restart_loop.set();
}

fn onCron(self: *@This(), plugin: Plugin, memory: []u8, inputs: []const wasm.Val, outputs: []wasm.Val) !void {
    std.debug.assert(inputs.len == 2);
    std.debug.assert(outputs.len == 1);

    var cron = Cron.init();
    try cron.parse(wasm.span(memory, inputs[1]));

    try self.addCallback(plugin.name(), try Callback.init(
        self.allocator,
        .{ .cron = cron },
        wasm.span(memory, inputs[0]),
    ));

    const next = try cron.next(Datetime.now());
    outputs[0] = .{ .i64 = @intCast(next.toTimestamp()) };

    self.restart_loop.set();
}
