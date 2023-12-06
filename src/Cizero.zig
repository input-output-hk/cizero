const std = @import("std");

const comps = @import("components.zig");

const Registry = @import("Registry.zig");

const Components = struct {
    http: *comps.Http,
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
    inline for (.{
        try self.components.http.start(),
        try self.components.timeout.start(),
    }) |thread| thread.join();
}

pub fn stop(self: *@This()) void {
    self.components.http.stop();
    self.components.timeout.stop();
}
