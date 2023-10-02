const std = @import("std");

const mods = @import("modules.zig");
const plugin = @import("plugin.zig");

const Module = @import("Module.zig");
const Plugin = plugin.Plugin;
const Registry = @import("Registry.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    const allocator = gpa.allocator();

    var registry = Registry.init(allocator);
    defer registry.deinit();

    var modules = struct{
        timeout: mods.Timeout,
        to_upper: mods.ToUpper,
    }{
        .timeout = mods.Timeout.init(allocator, &registry),
        .to_upper = .{},
    };

    try registry.modules.append(Module.init(&modules.timeout));
    try registry.modules.append(Module.init(&modules.to_upper));

    {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        _ = args.next(); // discard executable (not a plugin)
        while (args.next()) |arg| {
            const name = try registry.allocator.dupe(u8, std.fs.path.stem(arg));

            std.log.info("loading plugin \"{s}\"…", .{name});

            const wasm = try std.fs.cwd().readFileAlloc(registry.allocator, arg, std.math.maxInt(usize));
            try registry.plugins.put(name, Plugin.init(wasm));

            var runtime = try registry.runtime(name);
            defer runtime.deinit();

            if (!try runtime.main()) return error.PluginMainFailed;
        }
    }

    (try modules.timeout.start()).join();
}

test {
    _ = mods;
    _ = plugin;
    _ = Module;
    _ = Registry;
    _ = @import("wasm.zig");
    _ = @import("wasmtime.zig");
}
