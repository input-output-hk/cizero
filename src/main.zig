const std = @import("std");

const mods = @import("modules.zig");

const Module = @import("Module.zig");
const Plugin = @import("Plugin.zig");
const Registry = @import("Registry.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    const allocator = gpa.allocator();

    var registry = Registry.init(allocator);
    defer registry.deinit();

    var modules = struct {
        process: mods.Process,
        timeout: mods.Timeout,
        to_upper: mods.ToUpper,
    }{
        .process = .{ .allocator = allocator },
        .timeout = .{ .allocator = allocator, .registry = &registry },
        .to_upper = .{},
    };
    inline for (@typeInfo(@TypeOf(modules)).Struct.fields) |field|
        try registry.modules.append(Module.init(&@field(modules, field.name)));

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

    (try modules.timeout.start()).join();
}

test {
    _ = @import("enums.zig");
    _ = @import("mem.zig");
    _ = @import("meta.zig");
    _ = mods;
    _ = Module;
    _ = Plugin;
    _ = Registry;
    _ = @import("wasm.zig");
    _ = @import("wasmtime.zig");
}
