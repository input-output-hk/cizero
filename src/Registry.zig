const std = @import("std");
const zqlite = @import("zqlite");

const queries = @import("sql.zig").queries;

const Component = @import("Component.zig");
const Runtime = @import("Runtime.zig");

allocator: std.mem.Allocator,

db_pool: *zqlite.Pool,

components: std.ArrayListUnmanaged(Component) = .{},

wasi_config: Runtime.WasiConfig = .{},

pub fn deinit(self: *@This()) void {
    for (self.components.items) |*component| component.deinit();
    self.components.deinit(self.allocator);
}

pub fn registerComponent(self: *@This(), component_impl: anytype) !void {
    try self.components.append(self.allocator, Component.init(component_impl));
}

/// Runs the plugin's main function if it is a new version.
pub fn registerPlugin(self: *@This(), name: []const u8, wasm: []const u8) !void {
    {
        const conn = self.db_pool.acquire();
        defer self.db_pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        if (try queries.Plugin.SelectByName(&.{.wasm}).query(arena.allocator(), conn, .{name})) |row|
            if (std.mem.eql(u8, wasm, row.wasm.value)) {
                std.log.info("not registering already registered plugin: {s}", .{name});
                return;
            };
    }

    std.log.info("registering plugin: {s}", .{name});

    {
        const conn = self.db_pool.acquire();
        defer self.db_pool.release(conn);

        try queries.Plugin.insert.exec(conn, .{ name, .{ .value = wasm } });
    }

    var rt = try self.runtime(name);
    defer rt.deinit();

    if (!try rt.main()) return error.PluginMainFailed;
}

/// Remember to deinit after use.
pub fn runtime(self: *const @This(), plugin_name: []const u8) !Runtime {
    const conn = self.db_pool.acquire();
    defer self.db_pool.release(conn);

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const plugin = try queries.Plugin.SelectByName(&.{.wasm})
        .query(arena.allocator(), conn, .{plugin_name}) orelse
        return error.NoSuchPlugin;

    var host_functions = try self.hostFunctions(self.allocator);
    defer host_functions.deinit(self.allocator);

    var rt = try Runtime.init(
        self.allocator,
        plugin_name,
        plugin.wasm.value,
        host_functions,
    );
    errdefer rt.deinit();
    rt.wasi_config = &self.wasi_config;

    return rt;
}

/// Remember to deinit after use.
fn hostFunctions(self: @This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef) {
    var host_functions = std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef){};
    errdefer host_functions.deinit(allocator);

    try host_functions.ensureTotalCapacity(allocator, @intCast(self.components.items.len));

    for (self.components.items) |component| {
        var component_host_functions = try component.hostFunctions(allocator);
        defer component_host_functions.deinit(allocator);

        try host_functions.ensureUnusedCapacity(allocator, component_host_functions.count());

        var component_host_functions_iter = component_host_functions.iterator();
        while (component_host_functions_iter.next()) |entry|
            host_functions.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
    }

    return host_functions;
}
