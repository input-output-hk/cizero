const std = @import("std");

const Component = @import("Component.zig");
const Plugin = @import("Plugin.zig");

allocator: std.mem.Allocator,

components: std.ArrayListUnmanaged(Component) = .{}, // TODO should this be comptimestringmap?
plugins: std.StringArrayHashMapUnmanaged(Plugin) = .{},

wasi_config: Plugin.Runtime.WasiConfig = .{},

pub fn deinit(self: *@This()) void {
    for (self.plugins.values()) |v| self.allocator.free(v.path);
    self.plugins.deinit(self.allocator);

    for (self.components.items) |*component| component.deinit();
    self.components.deinit(self.allocator);
}

pub fn registerComponent(self: *@This(), component_impl: anytype) !void {
    try self.components.append(self.allocator, Component.init(component_impl));
}

/// Runs the plugin's main function if it is a new version.
pub fn registerPlugin(self: *@This(), plugin_borrowed: Plugin) !bool {
    const plugin = Plugin{
        .path = try self.allocator.dupe(u8, plugin_borrowed.path),
    };
    const plugin_name = plugin.name();

    if (try self.plugins.fetchPut(self.allocator, plugin_name, plugin)) |prev| {
        defer self.allocator.free(prev.value.path);

        std.debug.assert(std.mem.eql(u8, plugin.name(), prev.value.name()));

        const prev_wasm = try prev.value.wasm(self.allocator);
        defer self.allocator.free(prev_wasm);

        const plugin_wasm = try plugin.wasm(self.allocator);
        defer self.allocator.free(plugin_wasm);

        return !std.mem.eql(u8, plugin_wasm, prev_wasm);
    }

    std.log.info("registering plugin \"{s}\"…", .{plugin_name});

    var rt = try self.runtime(plugin_name);
    defer rt.deinit();

    if (!try rt.main()) return error.PluginMainFailed;

    return true;
}

/// Remember to deinit after use.
pub fn runtime(self: *const @This(), plugin_name: []const u8) !Plugin.Runtime {
    const p = self.plugins.get(plugin_name) orelse return error.NoSuchPlugin;

    var host_functions = try self.hostFunctions(self.allocator);
    defer host_functions.deinit(self.allocator);

    var rt = try Plugin.Runtime.init(self.allocator, p, host_functions);
    rt.wasi_config = &self.wasi_config;
    return rt;
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
