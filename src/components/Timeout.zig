const builtin = @import("builtin");
const std = @import("std");

const Cron = @import("cron").Cron;
const Datetime = @import("datetime").datetime.Datetime;

const lib = @import("lib");
const meta = lib.meta;
const wasm = lib.wasm;

const components = @import("../components.zig");
const sql = @import("../sql.zig");

const Registry = @import("../Registry.zig");
const Runtime = @import("../Runtime.zig");

pub const name = "timeout";

const Callback = enum {
    timestamp,
    cron,

    pub fn done(self: @This()) components.CallbackDoneCondition {
        return switch (self) {
            .timestamp => .always,
            .cron => .{ .on = .{} },
        };
    }
};

registry: *const Registry,

allocator: std.mem.Allocator,

loop_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
loop_wait: std.Thread.ResetEvent = .{},

mock_milli_timestamp: if (builtin.is_test) ?meta.Closure(@TypeOf(std.time.milliTimestamp), true) else void = if (builtin.is_test) null,

fn milliTimestamp(self: @This()) i64 {
    if (@TypeOf(self.mock_milli_timestamp) != void)
        if (self.mock_milli_timestamp) |mock| return mock.call(.{});
    return std.time.milliTimestamp();
}

pub fn start(self: *@This()) (std.Thread.SpawnError || std.Thread.SetNameError)!std.Thread {
    self.loop_run.store(true, .Monotonic);
    self.loop_wait.reset();

    const thread = try std.Thread.spawn(.{}, loop, .{self});
    thread.setName(name) catch |err| std.log.debug("could not set thread name: {s}", .{@errorName(err)});
    return thread;
}

pub fn stop(self: *@This()) void {
    self.loop_run.store(false, .Monotonic);
    self.loop_wait.set();
}

fn loop(self: *@This()) !void {
    while (self.loop_run.load(.Monotonic)) : (self.loop_wait.reset()) {
        const SelectNext = sql.queries.timeout_callback.SelectNext(&.{ .id, .plugin, .function, .user_data, .timestamp, .cron });
        const next_callback_row = blk: {
            const conn = self.registry.db_pool.acquire();
            defer self.registry.db_pool.release(conn);

            break :blk try SelectNext.row(conn, .{});
        };

        if (next_callback_row) |callback_row| {
            errdefer callback_row.deinit();

            {
                const now_ms = self.milliTimestamp();
                const next_timestamp = SelectNext.column(callback_row, .timestamp);
                if (now_ms < next_timestamp) {
                    const timeout_ns: u64 = @intCast((next_timestamp - now_ms) * std.time.ns_per_ms);
                    if (!std.meta.isError(self.loop_wait.timedWait(timeout_ns))) {
                        // `timedWait()` did not time out so `loop_wait` was `set()`.
                        // This could have been done by `stop()`. If so, we don't want to run the callback.
                        if (!self.loop_run.load(.Monotonic)) break;
                    }
                }
            }

            var callback: components.CallbackUnmanaged = undefined;
            try sql.structFromRow(self.allocator, &callback, callback_row, SelectNext.column, .{
                .func_name = .function,
                .user_data = .user_data,
            });
            defer callback.deinit(self.allocator);

            const callback_id = SelectNext.column(callback_row, .id);
            const callback_kind: Callback = if (SelectNext.column(callback_row, .cron) != null) .cron else .timestamp;

            // No need to heap-allocate here.
            // Just stack-allocate sufficient memory for all cases.
            var outputs_memory: [1]wasm.Value = undefined;
            const outputs = outputs_memory[0..switch (callback_kind) {
                .timestamp => 0,
                .cron => 1,
            }];

            var runtime = try self.registry.runtime(SelectNext.column(callback_row, .plugin));
            defer runtime.deinit();

            const success = try callback.run(self.allocator, runtime, &.{}, outputs);
            const done = callback_kind.done().check(success, outputs);

            if (done) {
                const conn = self.registry.db_pool.acquire();
                defer self.registry.db_pool.release(conn);

                try sql.queries.callback.deleteById.exec(conn, .{callback_id});
            } else switch (callback_kind) {
                .timestamp => {},
                .cron => {
                    var cron = Cron.init();
                    try cron.parse(SelectNext.column(callback_row, .cron).?);

                    const now_ms = self.milliTimestamp();
                    const next_timestamp: i64 = @intCast((try cron.next(Datetime.fromTimestamp(now_ms))).toTimestamp());

                    const conn = self.registry.db_pool.acquire();
                    defer self.registry.db_pool.release(conn);

                    try sql.queries.timeout_callback.updateTimestamp.exec(conn, .{ callback_id, next_timestamp });
                },
            }

            try callback_row.deinitErr();
        } else self.loop_wait.wait();
    }
}

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef) {
    return meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef), allocator, .{
        .on_timestamp = Runtime.HostFunctionDef{
            .signature = .{
                .params = &.{ .i32, .i32, .i32, .i64 },
                .returns = &.{},
            },
            .host_function = Runtime.HostFunction.init(onTimestamp, self),
        },
        .on_cron = Runtime.HostFunctionDef{
            .signature = .{
                .params = &[_]wasm.Value.Type{.i32} ** 4,
                .returns = &.{.i64},
            },
            .host_function = Runtime.HostFunction.init(onCron, self),
        },
    });
}

fn onTimestamp(self: *@This(), plugin_name: []const u8, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 4);
    std.debug.assert(outputs.len == 0);

    try components.rejectIfStopped(&self.loop_run);

    const params = .{
        .func_name = wasm.span(memory, inputs[0]),
        .user_data_ptr = @as([*]const u8, @ptrCast(&memory[@intCast(inputs[1].i32)])),
        .user_data_len = @as(wasm.usize, @intCast(inputs[2].i32)),
        .timestamp = inputs[3].i64,
    };

    const user_data = if (params.user_data_len != 0) params.user_data_ptr[0..params.user_data_len] else null;

    const conn = self.registry.db_pool.acquire();
    defer self.registry.db_pool.release(conn);

    try conn.transaction();
    errdefer conn.rollback();

    try sql.queries.callback.insert.exec(conn, .{
        plugin_name,
        params.func_name,
        if (user_data) |ud| .{ .value = ud } else null,
    });
    try sql.queries.timeout_callback.insert.exec(conn, .{
        conn.lastInsertedRowId(),
        params.timestamp,
        null,
    });

    try conn.commit();

    self.loop_wait.set();
}

fn onCron(self: *@This(), plugin_name: []const u8, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 4);
    std.debug.assert(outputs.len == 1);

    try components.rejectIfStopped(&self.loop_run);

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

    const next = try cron.next(Datetime.fromTimestamp(self.milliTimestamp()));
    outputs[0] = .{ .i64 = @intCast(next.toTimestamp()) };

    const conn = self.registry.db_pool.acquire();
    defer self.registry.db_pool.release(conn);

    try conn.transaction();
    errdefer conn.rollback();

    try sql.queries.callback.insert.exec(conn, .{
        plugin_name,
        params.func_name,
        if (user_data) |ud| .{ .value = ud } else null,
    });
    try sql.queries.timeout_callback.insert.exec(conn, .{
        conn.lastInsertedRowId(),
        outputs[0].i64,
        params.cron,
    });

    try conn.commit();

    self.loop_wait.set();
}
