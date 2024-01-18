const builtin = @import("builtin");
const std = @import("std");

const Cron = @import("cron").Cron;
const Datetime = @import("datetime").datetime.Datetime;

const components = @import("../components.zig");
const meta = @import("../meta.zig");
const wasm = @import("../wasm.zig");

const Plugin = @import("../Plugin.zig");
const Registry = @import("../Registry.zig");

pub const name = "timeout";

registry: *const Registry,

allocator: std.mem.Allocator,

plugin_callbacks: components.CallbacksUnmanaged(union(enum) {
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

    pub fn done(self: @This()) components.CallbackDoneCondition {
        return switch (self) {
            .timestamp => .always,
            .cron => .{ .on = .{} },
        };
    }
}) = .{},

loop_run: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(true),
loop_wait: std.Thread.ResetEvent = .{},

mock_milli_timestamp: if (builtin.is_test) ?meta.Closure(@TypeOf(std.time.milliTimestamp), true) else void = if (builtin.is_test) null,

fn milliTimestamp(self: @This()) i64 {
    if (@TypeOf(self.mock_milli_timestamp) != void)
        if (self.mock_milli_timestamp) |mock| return mock.call(.{});
    return std.time.milliTimestamp();
}

pub fn deinit(self: *@This()) void {
    self.plugin_callbacks.deinit(self.allocator);
}

pub fn start(self: *@This()) (std.Thread.SpawnError || std.Thread.SetNameError)!std.Thread {
    const thread = try std.Thread.spawn(.{}, loop, .{self});
    thread.setName(name) catch |err| std.log.debug("could not set thread name: {s}", .{@errorName(err)});
    return thread;
}

/// Cannot be started again once stopped.
pub fn stop(self: *@This()) void {
    self.loop_run.store(false, .Monotonic);
    self.loop_wait.set();
}

fn loop(self: *@This()) !void {
    while (self.loop_run.load(.Monotonic)) : (self.loop_wait.reset()) {
        const now_ms = self.milliTimestamp();

        const next_callback = blk: {
            var next: ?@TypeOf(self.plugin_callbacks).Entry = null;

            var plugin_callbacks_iter = self.plugin_callbacks.iterator();
            while (plugin_callbacks_iter.next()) |entry| {
                // XXX do not compute `entry.callbackPtr().condition.next()` multiple times
                // XXX do not compute `next.?.callbackPtr().timeout.next()` multiple times
                if (next == null or try entry.callbackPtr().condition.next(now_ms) < try next.?.callbackPtr().condition.next(now_ms)) next = entry;
            }

            break :blk next;
        };

        if (next_callback) |next| {
            const callback = next.callbackPtr();

            {
                const next_timestamp = try callback.condition.next(now_ms);
                if (now_ms < next_timestamp) {
                    const timeout_ns: u64 = @intCast((next_timestamp - now_ms) * std.time.ns_per_ms);
                    if (!std.meta.isError(self.loop_wait.timedWait(timeout_ns))) {
                        // `timedWait()` did not time out so `loop_wait` was `set()`.
                        // This could have been done by `stop()`. If so, we don't want to run the callback.
                        if (!self.loop_run.load(.Monotonic)) break;
                    }
                }
            }

            // No need to heap-allocate here.
            // Just stack-allocate sufficient memory for all cases.
            var outputs_memory: [1]wasm.Value = undefined;
            var outputs = outputs_memory[0..switch (callback.condition) {
                .timestamp => 0,
                .cron => 1,
            }];

            var runtime = try self.registry.runtime(next.pluginName());
            defer runtime.deinit();

            _ = try next.run(self.allocator, runtime, &.{}, outputs);
        } else self.loop_wait.wait();
    }
}

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    return meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef), allocator, .{
        .on_timestamp = Plugin.Runtime.HostFunctionDef{
            .signature = .{
                .params = &.{ .i32, .i32, .i32, .i64 },
                .returns = &.{},
            },
            .host_function = Plugin.Runtime.HostFunction.init(onTimestamp, self),
        },
        .on_cron = Plugin.Runtime.HostFunctionDef{
            .signature = .{
                .params = &[_]wasm.Value.Type{.i32} ** 4,
                .returns = &.{.i64},
            },
            .host_function = Plugin.Runtime.HostFunction.init(onCron, self),
        },
    });
}

fn onTimestamp(self: *@This(), plugin: Plugin, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 4);
    std.debug.assert(outputs.len == 0);

    const params = .{
        .func_name = wasm.span(memory, inputs[0]),
        .user_data_ptr = @as([*]const u8, @ptrCast(&memory[@intCast(inputs[1].i32)])),
        .user_data_len = @as(wasm.usize, @intCast(inputs[2].i32)),
        .timestamp = inputs[3].i64,
    };

    const user_data = if (params.user_data_len != 0) params.user_data_ptr[0..params.user_data_len] else null;

    try self.plugin_callbacks.insert(
        self.allocator,
        plugin.name(),
        params.func_name,
        user_data,
        .{ .timestamp = params.timestamp },
    );

    self.loop_wait.set();
}

fn onCron(self: *@This(), plugin: Plugin, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 4);
    std.debug.assert(outputs.len == 1);

    const params = .{
        .func_name = wasm.span(memory, inputs[0]),
        .user_data_ptr = blk: {
            const addr: wasm.usize = @intCast(inputs[1].i32);
            break :blk if (addr == 0) null else @as([*]const u8, @ptrCast(&memory[addr]));
        },
        .user_data_len = @as(wasm.usize, @intCast(inputs[2].i32)),
        .cron = wasm.span(memory, inputs[3]),
    };

    const user_data = if (params.user_data_ptr) |ptr| ptr[0..params.user_data_len] else null;

    var cron = Cron.init();
    try cron.parse(params.cron);

    try self.plugin_callbacks.insert(
        self.allocator,
        plugin.name(),
        params.func_name,
        user_data,
        .{ .cron = cron },
    );

    const next = try cron.next(Datetime.fromTimestamp(self.milliTimestamp()));
    outputs[0] = .{ .i64 = @intCast(next.toTimestamp()) };

    self.loop_wait.set();
}
