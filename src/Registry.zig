const std = @import("std");

const Module = @import("Module.zig");
const Plugin = @import("Plugin.zig");

allocator: std.mem.Allocator,

modules: std.ArrayList(Module), // TODO should this be comptimestringmap?
plugins: std.StringArrayHashMap(Plugin),

pub fn deinit(self: *@This()) void {
    for (self.plugins.values()) |v| v.deinit(self.allocator);
    self.plugins.deinit();

    for (self.modules.items) |*m| m.deinit();
    self.modules.deinit();
}

pub fn init(allocator: std.mem.Allocator) @This() {
    return .{
        .allocator = allocator,
        .modules = std.ArrayList(Module).init(allocator),
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
    try host_functions.ensureTotalCapacity(allocator, @intCast(self.modules.items.len));

    for (self.modules.items) |m| {
        var module_host_functions = try m.hostFunctions(allocator);
        defer module_host_functions.deinit(allocator);

        var module_host_functions_iter = module_host_functions.iterator();
        while (module_host_functions_iter.next()) |entry|
            try host_functions.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    return host_functions;
}
