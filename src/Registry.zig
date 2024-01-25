const std = @import("std");
const zqlite = @import("zqlite");

const lib = @import("lib");
const mem = lib.mem;

const queries = @import("sql.zig").queries;

const Component = @import("Component.zig");
const Runtime = @import("Runtime.zig");

allocator: std.mem.Allocator,

db_pool: *zqlite.Pool,

components: std.ArrayListUnmanaged(Component) = .{}, // TODO should this be comptimestringmap?

wasi_config: Runtime.WasiConfig = .{},

pub fn deinit(self: *@This()) void {
    for (self.components.items) |*component| component.deinit();
    self.components.deinit(self.allocator);
}

pub fn registerComponent(self: *@This(), component_impl: anytype) !void {
    try self.components.append(self.allocator, Component.init(component_impl));
}

/// Runs the plugin's main function if it is a new version.
pub fn registerPlugin(self: *@This(), name: []const u8, wasm: []const u8) !bool {
    {
        const conn = self.db_pool.acquire();
        defer self.db_pool.release(conn);

        try queries.plugins.insert(conn, name, wasm);
    }

    std.log.info("registering plugin \"{s}\"…", .{name});

    var rt = try self.runtime(.{ .data = name, .owned = false });
    defer rt.deinit();

    if (!try rt.main()) return error.PluginMainFailed;

    return true;
}

/// Remember to deinit after use.
pub fn runtime(self: *const @This(), plugin_name: mem.Borrowned([]const u8)) !Runtime {
    const plugin_wasm = blk: {
        const conn = self.db_pool.acquire();
        defer self.db_pool.release(conn);

        break :blk try queries.plugins.getWasm(self.allocator, conn, plugin_name.data);
    };

    var host_functions = try self.hostFunctions(self.allocator);
    defer host_functions.deinit(self.allocator);

    var rt = try Runtime.init(
        self.allocator,

        // XXX In all known cases,
        // `plugin_name` is borrowed and
        // `plugin_wasm` is owned;
        // Can we get rid of `mem.Borrowned`?
        // How do we make the ownership semantics
        // obvious? It's confusing if
        // the name is borrowed even though
        // we take an allocator.
        // Should we just copy the name and wasm?
        // But that's a waste!
        plugin_name,
        .{ .data = plugin_wasm, .owned = true },

        host_functions,
    );
    rt.wasi_config = &self.wasi_config;
    return rt;
}

/// Remember to deinit after use.
fn hostFunctions(self: @This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef) {
    var host_functions = std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef){};
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
