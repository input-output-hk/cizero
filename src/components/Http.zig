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

const log = std.log.scoped(.http);

const Callback = enum {
    webhook,

    pub fn done(_: @This()) components.CallbackDoneCondition {
        return .{ .on = .{ .failure = false } };
    }
};

registry: *const Registry,
wait_group: *std.Thread.WaitGroup,

allocator: std.mem.Allocator,

server: httpz.ServerCtx(*@This(), *@This()),

pub fn deinit(self: *@This()) void {
    self.server.deinit();
    self.allocator.destroy(self);
}

pub const InitError = std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator, registry: *const Registry, wait_group: *std.Thread.WaitGroup) InitError!*@This() {
    var self = try allocator.create(@This());
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .server = try httpz.ServerCtx(*@This(), *@This()).init(allocator, .{}, self),
        .registry = registry,
        .wait_group = wait_group,
    };

    var router = self.server.router();
    router.post("/webhook/:plugin", postWebhook);

    return self;
}

pub fn start(self: *@This()) (std.Thread.SpawnError || std.Thread.SetNameError)!void {
    self.wait_group.start();
    errdefer self.wait_group.finish();

    const thread = try std.Thread.spawn(.{}, run, .{self});
    thread.setName(name) catch |err| log.debug("could not set thread name: {s}", .{@errorName(err)});
    thread.detach();
}

fn run(self: *@This()) !void {
    defer self.wait_group.finish();

    try self.server.listen();
}

pub fn stop(self: *@This()) void {
    self.server.stop();
}

fn postWebhook(self: *@This(), req: *httpz.Request, res: *httpz.Response) !void {
    const plugin_name = req.param("plugin") orelse {
        res.status = 404;
        return;
    };

    const callback_row = row: {
        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        break :row try sql.queries.HttpCallback.SelectCallbackByPlugin(&.{ .id, .plugin, .function, .user_data })
            .query(res.arena, conn, .{plugin_name}) orelse {
            res.status = 404;
            return;
        };
    };

    res.status = 204;

    const callback = components.CallbackUnmanaged{
        .func_name = try res.arena.dupeZ(u8, callback_row.function),
        .user_data = if (callback_row.user_data) |ud| ud.value else null,
    };

    var runtime = try self.registry.runtime(callback_row.plugin);
    defer runtime.deinit();

    const linear = try runtime.linearMemoryAllocator();
    const allocator = linear.allocator();

    const req_body = if (req.body()) |req_body| try allocator.dupeZ(u8, req_body) else null;
    defer if (req_body) |b| allocator.free(b);

    const res_status = try allocator.create(u16);
    defer allocator.destroy(res_status);
    res_status.* = res.status;

    const res_body_addr = try allocator.create(wasm.usize);
    defer allocator.destroy(res_body_addr);
    res_body_addr.* = 0;

    const inputs = [_]wasm.Value{
        .{ .i32 = if (req_body) |b| @intCast(linear.memory.offset(b.ptr)) else 0 },
        .{ .i32 = @intCast(linear.memory.offset(res_status)) },
        .{ .i32 = @intCast(linear.memory.offset(res_body_addr)) },
    };

    var outputs: [1]wasm.Value = undefined;

    const success = try callback.run(self.allocator, runtime, &inputs, &outputs);

    if (Callback.webhook.done().check(success, &outputs)) {
        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        try sql.queries.Callback.deleteById.exec(conn, .{callback_row.id});
    }

    res.status = res_status.*;

    if (res_body_addr.* != 0) {
        const res_body = wasm.span(linear.memory.slice(), res_body_addr.*);
        try res.directWriter().writeAll(res_body);

        // No need to free `res_body` as it is destroyed with `runtime` anyway.
        // This way the plugin is also allowed to point us to its constant data.
    }
}

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef) {
    return meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef), allocator, .{
        .http_on_webhook = Runtime.HostFunctionDef{
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

    try sql.queries.Callback.insert.exec(conn, .{
        plugin_name,
        params.func_name,
        if (user_data) |ud| .{ .value = ud } else null,
    });
    try sql.queries.HttpCallback.insert.exec(conn, .{
        conn.lastInsertedRowId(),
        plugin_name,
    });

    try conn.commit();
}
