const std = @import("std");
const extism = @import("extism");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    const alloc = gpa.allocator();

    var extism_ctx = extism.Context.init();
    defer extism_ctx.deinit();

    var extism_funcs = initHostFunctions(alloc);
    defer deinitHostFunctions(&extism_funcs);

    {
        const extism_manifest = .{ .wasm = &.{.{ .wasm_file = .{ .path = "zig-out/bin/foo.wasm" } }} };

        // FIXME cannot use `Plugin.createFromManifest()` since it was broken in
        // https://github.com/extism/extism/commit/0f8954c2039cdffbb53352df6f613e4bbbb74235
        var extism_plugin = try extism.Plugin.initFromManifest(
            alloc,
            &extism_ctx,
            extism_manifest,
            &extism_funcs,
            true,
        );
        defer extism_plugin.deinit();

        if (extism_plugin.call("cizero_plugin_fib", "12")) |output| {
            try std.testing.expectEqualStrings("233", output);
        } else |_| std.debug.print("call error: {s}\n", .{extism_plugin.error_info.?});

        if (extism_plugin.call("cizero_plugin_toUpper", "hello world")) |output| {
            try std.testing.expectEqualStrings("HELLO WORLD", output);
        } else |_| std.debug.print("call error: {s}\n", .{extism_plugin.error_info.?});
    }
}

fn initHostFunctions(allocator: std.mem.Allocator) [2]extism.Function {
    const funcs = struct{
        export fn add(
            _: ?*extism.c.ExtismCurrentPlugin,
            inputs_ptr: [*c]const extism.c.ExtismVal,
            inputs_len: u64,
            outputs_ptr: [*c]extism.c.ExtismVal,
            outputs_len: u64,
            _: ?*anyopaque,
        ) callconv(.C) void {
            std.debug.assert(inputs_len == 2);
            std.debug.assert(outputs_len == 1);

            outputs_ptr.* = extism.c.ExtismVal{
                .t = extism.c.I32,
                .v = .{ .i32 = inputs_ptr[0].v.i32 + inputs_ptr[1].v.i32 },
            };
        }

        export fn toUpper(
            plugin_ptr: ?*extism.c.ExtismCurrentPlugin,
            inputs_ptr: [*c]const extism.c.ExtismVal,
            inputs_len: u64,
            outputs_ptr: [*c]extism.c.ExtismVal,
            outputs_len: u64,
            allocator_ptr: ?*anyopaque,
        ) callconv(.C) void {
            std.debug.assert(inputs_len == 1);
            std.debug.assert(outputs_len == 1);

            var plugin = extism.CurrentPlugin.getCurrentPlugin(plugin_ptr orelse unreachable);
            const alloc: *const std.mem.Allocator = @alignCast(@ptrCast(allocator_ptr));

            const inputs = inputs_ptr[0..inputs_len];

            const lower = plugin.inputBytes(&inputs[0]);

            std.debug.print("toUpper input: {s}\n", .{lower});

            var upper_buf = alloc.alloc(u8, lower.len) catch unreachable;
            defer alloc.free(upper_buf);

            const upper = std.ascii.upperString(upper_buf, lower);

            extism_fixes.CurrentPlugin.returnBytes(&plugin, outputs_ptr, upper);
        }
    };

    var func_refs = [_]extism.Function{
        extism.Function.init(
            "add",
            &.{extism.c.I32, extism.c.I32},
            &.{extism.c.I32},
            funcs.add,
            null,
        ),
        extism.Function.init(
            "toUpper",
            &.{extism.c.I64},
            &.{extism.c.I64},
            funcs.toUpper,
            @constCast(&allocator),
        ),
    };
    for (&func_refs) |*func_ref| func_ref.setNamespace("cizero");
    return func_refs;
}

fn deinitHostFunctions(funcs: []extism.Function) void {
    for (funcs) |*func| func.deinit();
}

// FIXME fixes that should be upstreamed
const extism_fixes = struct {
    // TODO `Memory` is not pub...

    const CurrentPlugin = struct {
        const Self = extism.CurrentPlugin;

        fn getMemory(self: Self, offset: u64) []u8 {
            const len = extism.c.extism_current_plugin_memory_length(self.c_currplugin, offset);
            const c_data = extism.c.extism_current_plugin_memory(self.c_currplugin);
            const data: [*:0]u8 = std.mem.span(c_data);
            return data[offset .. offset + len];
        }

        fn returnBytes(self: *Self, val: *extism.c.ExtismVal, data: []const u8) void {
            const mem = self.alloc(@as(u64, data.len));
            var ptr = getMemory(self.*, mem);
            @memcpy(ptr, data);
            val.v.i64 = @intCast(mem);
        }
    };
};
