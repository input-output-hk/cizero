const std = @import("std");

const extism = @import("extism-pdk");

const allocator = std.heap.wasm_allocator;

const Plugin = @This();

const cizero = struct {
    const ext = struct {
        extern "cizero" fn add(i32, i32) i32;
        extern "cizero" fn toUpper(i64) i64;
    };

    pub const add = ext.add;

    pub fn toUpper(lower: []const u8) extism.Memory {
        const memory = extism.Memory.allocateBytes(lower);
        defer memory.free();
        return extism.Memory.init(ext.toUpper(memory.offset), lower.len);
    }
};

pub export fn cizero_plugin_fib() i32 {
    const plugin = extism.Plugin.init(allocator);
    const input = plugin.getInput() catch unreachable;
    defer allocator.free(input);

    const n = std.fmt.parseInt(i32, input, 10) catch |err| return reportError(err);

    const result = Plugin.fib(n);

    const output = std.fmt.allocPrint(allocator, "{d}", .{result}) catch |err| return reportError(err);
    defer allocator.free(output);

    plugin.output(output);

    return 0;
}

fn fib(n: i32) i32 {
    if (n < 2) return 1;
    return cizero.add(fib(n - 2), fib(n - 1));
}

pub export fn cizero_plugin_toUpper() i32 {
    const plugin = extism.Plugin.init(allocator);
    const input = plugin.getInput() catch |err| return reportError(err);
    defer plugin.allocator.free(input);

    const output_mem = cizero.toUpper(input);
    defer output_mem.free();

    plugin.outputMemory(output_mem);

    return 0;
}

// fn mainToUpper() !void {
//     var args = std.process.argsWithAllocator(allocator) catch unreachable;
//     defer args.deinit();

//     while (args.next()) |arg| {
//         const upper = try cizero.toUpper(allocator, arg);
//         defer allocator.free(upper);

//         try std.io.getStdOut().writer().print("{s} → {s} ({d})\n", .{arg, upper, upper.len});
//     }
// }

fn reportError(err: anyerror) i32 {
    const msg = std.fmt.allocPrintZ(allocator, "{any}", .{err}) catch return 2;
    defer allocator.free(msg);

    // FIXME not exposed. fix upstream?
    // extism.c.extism_error_set(msg.ptr);

    const plugin = extism.Plugin.init(allocator);
    plugin.log(.Error, msg);

    return 1;
}

pub fn main() void {
    std.io.getStdOut().writer().print("hello from WASI\n", .{}) catch unreachable;

    // const exit_code = 2;
    // std.process.exit(exit_code);
    // return exit_code;
}

test {
    _ = extism;
}
