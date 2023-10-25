const std = @import("std");
const httpz = @import("httpz");

const meta = @import("../meta.zig");
const modules = @import("../modules.zig");
const wasm = @import("../wasm.zig");

const Plugin = @import("../Plugin.zig");
const Registry = @import("../Registry.zig");

pub const name = "http";

registry: *const Registry,

allocator: std.mem.Allocator,

plugin_callbacks: modules.CallbacksUnmanaged(union(enum) {
    webhook,

    pub fn done(_: @This()) modules.CallbackDoneCondition {
        return .{ .on = .{} };
    }
}) = .{},

server: httpz.ServerCtx(*@This(), *@This()),

pub fn deinit(self: *@This()) void {
    self.plugin_callbacks.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn init(allocator: std.mem.Allocator, registry: *const Registry) !*@This() {
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

pub fn start(self: *@This()) !std.Thread {
    const thread = try std.Thread.spawn(.{}, listen, .{self});
    try thread.setName(name);
    return thread;
}

fn listen(self: *@This()) !void {
    return self.server.listen();
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

        const body = if (try req.body()) |body| try allocator.dupeZ(u8, body) else null;
        defer if (body) |b| allocator.free(b);

        const inputs = [_]wasm.Value{
            .{ .i32 = if (body) |b| @intCast(linear.memory.offset(b.ptr)) else 0 },
        };

        var outputs: [1]wasm.Value = undefined;
        try entry.run(self.allocator, runtime, &inputs, &outputs);
    }

    res.status = 204;
}

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    return meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef), allocator, .{
        .onWebhook = Plugin.Runtime.HostFunctionDef{
            .signature = .{
                .params = &.{.i32},
                .returns = &.{},
            },
            .host_function = Plugin.Runtime.HostFunction.init(onWebhook, self),
        },
    });
}

fn onWebhook(self: *@This(), plugin: Plugin, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 1);
    std.debug.assert(outputs.len == 0);

    try self.plugin_callbacks.insert(
        self.allocator,
        plugin.name(),
        wasm.span(memory, inputs[0]),
        .webhook,
    );
}
