const std = @import("std");
const httpz = @import("httpz");

const components = @import("../components.zig");
const meta = @import("../meta.zig");
const wasm = @import("../wasm.zig");

const Plugin = @import("../Plugin.zig");
const Registry = @import("../Registry.zig");

pub const name = "http";

registry: *const Registry,

allocator: std.mem.Allocator,

plugin_callbacks: components.CallbacksUnmanaged(union(enum) {
    webhook,

    pub fn done(_: @This()) components.CallbackDoneCondition {
        return .{ .on = .{} };
    }
}) = .{},

server: httpz.ServerCtx(*@This(), *@This()),

pub fn deinit(self: *@This()) void {
    self.server.deinit();
    self.plugin_callbacks.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub const InitError = std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator, registry: *const Registry) InitError!*@This() {
    var self = try allocator.create(@This());
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
    try thread.setName(name);
    return thread;
}

pub fn stop(self: *@This()) void {
    self.server.stop();
}

fn postWebhook(self: *@This(), req: *httpz.Request, res: *httpz.Response) !void {
    var callbacks = try std.ArrayListUnmanaged(@TypeOf(self.plugin_callbacks).Entry).initCapacity(self.allocator, self.plugin_callbacks.map.count());
    defer callbacks.deinit(self.allocator);

    {
        var plugin_callbacks_iter = self.plugin_callbacks.iterator();
        while (plugin_callbacks_iter.next()) |entry| {
            if (entry.callbackPtr().condition != .webhook) continue;
            try callbacks.append(self.allocator, entry);
        }
    }

    for (callbacks.items) |entry| {
        var runtime = try self.registry.runtime(entry.pluginName());
        defer runtime.deinit();

        const linear = try runtime.linearMemoryAllocator();
        const allocator = linear.allocator();

        const body = if (req.body()) |body| try allocator.dupeZ(u8, body) else null;
        defer if (body) |b| allocator.free(b);

        const inputs = [_]wasm.Value{
            .{ .i32 = if (body) |b| @intCast(linear.memory.offset(b.ptr)) else 0 },
        };

        var outputs: [1]wasm.Value = undefined;
        _ = try entry.run(self.allocator, runtime, &inputs, &outputs);
    }

    res.status = 204;
}

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    return meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef), allocator, .{
        .on_webhook = Plugin.Runtime.HostFunctionDef{
            .signature = .{
                .params = &.{ .i32, .i32, .i32 },
                .returns = &.{},
            },
            .host_function = Plugin.Runtime.HostFunction.init(onWebhook, self),
        },
    });
}

fn onWebhook(self: *@This(), plugin: Plugin, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 3);
    std.debug.assert(outputs.len == 0);

    const params = .{
        .func_name = wasm.span(memory, inputs[0]),
        .user_data_ptr = @as([*]const u8, @ptrCast(&memory[@intCast(inputs[1].i32)])),
        .user_data_len = @as(wasm.usize, @intCast(inputs[2].i32)),
    };

    const user_data = if (params.user_data_len != 0) params.user_data_ptr[0..params.user_data_len] else null;

    try self.plugin_callbacks.insert(
        self.allocator,
        plugin.name(),
        params.func_name,
        user_data,
        .webhook,
    );
}
