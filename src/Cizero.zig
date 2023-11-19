const std = @import("std");

const comps = @import("components.zig");

const Registry = @import("Registry.zig");

const Components = struct {
    http: *comps.Http,
    nix: comps.Nix,
    process: comps.Process,
    timeout: comps.Timeout,
};

registry: Registry,
components: Components,

pub fn deinit(self: *@This()) void {
    self.registry.deinit();
    self.registry.allocator.destroy(self);
}

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!*@This() {
    var self = try allocator.create(@This());

    var http = try comps.Http.init(allocator, &self.registry);
    errdefer http.deinit();

    self.* = .{
        .registry = .{ .allocator = allocator },
        .components = .{
            .http = http,
            .nix = .{},
            .process = .{ .allocator = allocator },
            .timeout = .{ .allocator = allocator, .registry = &self.registry },
        },
    };

    inline for (@typeInfo(Components).Struct.fields) |field| {
        const value_ptr = &@field(self.components, field.name);
        try self.registry.registerComponent(if (comptime std.meta.trait.isSingleItemPtr(field.type)) value_ptr.* else value_ptr);
    }

    return self;
}

pub fn run(self: *@This()) !void {
    var threads_buf: [Components.fields.len]std.Thread = undefined;
    var threads: []const std.Thread = threads_buf[0..0];

    for (self.registry.components.items) |component|
        if (try component.start()) |thread| {
            threads_buf[threads.len] = thread;
            threads = threads_buf[0 .. threads.len + 1];
        };

    for (threads) |thread| thread.join();
}

pub fn stop(self: *@This()) void {
    for (self.registry.components.items) |component| component.stop();
}
