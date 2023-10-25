const std = @import("std");

const Component = @import("Component.zig");
const Plugin = @import("Plugin.zig");

allocator: std.mem.Allocator,

components: std.ArrayList(Component), // TODO should this be comptimestringmap?
plugins: std.StringArrayHashMap(Plugin),

pub fn deinit(self: *@This()) void {
    for (self.plugins.values()) |v| v.deinit(self.allocator);
    self.plugins.deinit();

    for (self.components.items) |*component| component.deinit();
    self.components.deinit();
}

pub fn init(allocator: std.mem.Allocator) @This() {
    return .{
        .allocator = allocator,
        .components = std.ArrayList(Component).init(allocator),
        .plugins = std.StringArrayHashMap(Plugin).init(allocator),
    };
}

/// Remember to deinit after use.
pub fn runtime(self: @This(), plugin_name: []const u8) !Plugin.Runtime {
    const p = self.plugins.get(plugin_name) orelse return error.NoSuchPlugin;

    var host_functions = try self.hostFunctions(self.allocator);
    defer host_functions.deinit(self.allocator);

    return try Plugin.Runtime.init(self.allocator, p, host_functions);
}

/// Remember to deinit after use.
fn hostFunctions(self: @This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    var host_functions = std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef){};
    try host_functions.ensureTotalCapacity(allocator, @intCast(self.components.items.len));

    for (self.components.items) |component| {
        var component_host_functions = try component.hostFunctions(allocator);
        defer component_host_functions.deinit(allocator);

        var component_host_functions_iter = component_host_functions.iterator();
        while (component_host_functions_iter.next()) |entry|
            try host_functions.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    return host_functions;
}
