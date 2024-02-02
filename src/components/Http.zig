const std = @import("std");
const httpz = @import("httpz");

const lib = @import("lib");
const meta = lib.meta;
const wasm = lib.wasm;

const components = @import("../components.zig");
const sql = @import("../sql.zig");

const Registry = @import("../Registry.zig");
const Runtime = @import("../Runtime.zig");

pub const name = "http";

const Callback = enum {
    webhook,

    pub fn done(_: @This()) components.CallbackDoneCondition {
        return .{ .on = .{} };
    }
};

registry: *const Registry,

allocator: std.mem.Allocator,

server: httpz.ServerCtx(*@This(), *@This()),

pub fn deinit(self: *@This()) void {
    self.server.deinit();
    self.allocator.destroy(self);
}

pub const InitError = std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator, registry: *const Registry) InitError!*@This() {
    var self = try allocator.create(@This());
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .server = try httpz.ServerCtx(*@This(), *@This()).init(allocator, .{}, self),
        .registry = registry,
    };

    var router = self.server.router();
    router.post("/webhook", postWebhook);

    return self;
}

pub fn start(self: *@This()) (std.Thread.SpawnError || std.Thread.SetNameError)!std.Thread {
    const thread = try self.server.listenInNewThread();
    thread.setName(name) catch |err| std.log.debug("could not set thread name: {s}", .{@errorName(err)});
    return thread;
}

pub fn stop(self: *@This()) void {
    self.server.stop();
}

fn postWebhook(self: *@This(), req: *httpz.Request, res: *httpz.Response) !void {
    const SelectCallback = sql.queries.http_callback.SelectCallback(&.{ .id, .plugin, .function, .user_data });
    var callback_rows = blk: {
        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        break :blk try SelectCallback.rows(conn, .{});
    };
    errdefer callback_rows.deinit();

    while (callback_rows.next()) |callback_row| {
        var callback: components.CallbackUnmanaged = undefined;
        try sql.structFromRow(self.allocator, &callback, callback_row, SelectCallback.column, .{
            .func_name = .function,
            .user_data = .user_data,
        });
        defer callback.deinit(self.allocator);

        var runtime = try self.registry.runtime(SelectCallback.column(callback_row, .plugin));
        defer runtime.deinit();

        const linear = try runtime.linearMemoryAllocator();
        const allocator = linear.allocator();

        const body = if (req.body()) |body| try allocator.dupeZ(u8, body) else null;
        defer if (body) |b| allocator.free(b);

        const inputs = [_]wasm.Value{
            .{ .i32 = if (body) |b| @intCast(linear.memory.offset(b.ptr)) else 0 },
        };

        var outputs: [1]wasm.Value = undefined;

        const success = try callback.run(self.allocator, runtime, &inputs, &outputs);

        if (Callback.webhook.done().check(success, &outputs)) {
            const callback_id = SelectCallback.column(callback_row, .id);

            const conn = self.registry.db_pool.acquire();
            defer self.registry.db_pool.release(conn);

            try sql.queries.callback.deleteById.exec(conn, .{callback_id});
        }
    }

    try callback_rows.deinitErr();

    res.status = 204;
}

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef) {
    return meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef), allocator, .{
        .on_webhook = Runtime.HostFunctionDef{
            .signature = .{
                .params = &.{ .i32, .i32, .i32 },
                .returns = &.{},
            },
            .host_function = Runtime.HostFunction.init(onWebhook, self),
        },
    });
}

fn onWebhook(self: *@This(), plugin_name: []const u8, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 3);
    std.debug.assert(outputs.len == 0);

    const params = .{
        .func_name = wasm.span(memory, inputs[0]),
        .user_data_ptr = @as([*]const u8, @ptrCast(&memory[@intCast(inputs[1].i32)])),
        .user_data_len = @as(wasm.usize, @intCast(inputs[2].i32)),
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
    try sql.queries.http_callback.insert.exec(conn, .{conn.lastInsertedRowId()});

    try conn.commit();
}
