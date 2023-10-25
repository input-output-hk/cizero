const std = @import("std");

const comps = @import("components.zig");

const Component = @import("Component.zig");
const Plugin = @import("Plugin.zig");
const Registry = @import("Registry.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    const allocator = gpa.allocator();

    var registry = Registry.init(allocator);
    defer registry.deinit();

    var components = struct {
        http: *comps.Http,
        process: comps.Process,
        timeout: comps.Timeout,
        to_upper: comps.ToUpper,
    }{
        .http = try comps.Http.init(allocator, &registry),
        .process = .{ .allocator = allocator },
        .timeout = .{ .allocator = allocator, .registry = &registry },
        .to_upper = .{},
    };
    inline for (@typeInfo(@TypeOf(components)).Struct.fields) |field| {
        const value_ptr = &@field(components, field.name);
        try registry.components.append(Component.init(
            if (comptime std.meta.trait.isSingleItemPtr(field.type)) value_ptr.*
            else value_ptr
        ));
    }

    {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        _ = args.next(); // discard executable (not a plugin)
        while (args.next()) |arg| {
            const plugin = Plugin{
                .path = try registry.allocator.dupe(u8, arg),
            };
            const plugin_name = plugin.name();

            std.log.info("registering plugin \"{s}\"…", .{plugin_name});

            try registry.plugins.put(plugin_name, plugin);

            var runtime = try registry.runtime(plugin_name);
            defer runtime.deinit();

            if (!try runtime.main()) return error.PluginMainFailed;
        }
    }

    inline for (.{
        try components.timeout.start(),
        try components.http.start(),
    }) |thread| thread.join();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
