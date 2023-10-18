const std = @import("std");

const modules = @import("../modules.zig");
const wasm = @import("../wasm.zig");

const Plugin = @import("../Plugin.zig");

pub const name = "process";

allocator: std.mem.Allocator,

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    return modules.stringArrayHashMapUnmanagedFromStruct(Plugin.Runtime.HostFunctionDef, allocator, .{
        .exec = Plugin.Runtime.HostFunctionDef{
            .signature = .{
                .params = &[_]wasm.ValueType{.{ .val = .i32 }} ** 11,
                .returns = &.{.{ .val = .i32}},
            },
            .host_function = Plugin.Runtime.HostFunction.init(exec, self),
        },
    });
}

fn exec(self: *@This(), _: Plugin, memory: []u8, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 11);
    std.debug.assert(outputs.len == 1);

    const params = .{
        .argv_ptr = @as([*]const wasm.usize, @alignCast(@ptrCast(&memory[@intCast(inputs[0].val.i32)]))),
        .argc = @as(wasm.usize, @intCast(inputs[1].val.i32)),
        .expand_arg0 = @as(std.process.Child.Arg0Expand, switch (inputs[2].val.i32) {
            1 => .expand,
            0 => .no_expand,
            else => unreachable,
        }),
        .env_map = @as(?[*]const wasm.usize, @alignCast(@ptrCast(&memory[@intCast(inputs[3].val.i32)]))),
        .env_map_len = @as(wasm.usize, @intCast(inputs[4].val.i32)),
        .max_output_bytes = @as(wasm.usize, @intCast(inputs[5].val.i32)),
        .output_ptr = @as([*]u8, @ptrCast(&memory[@intCast(inputs[6].val.i32)])),
        .stdout_len = @as(*wasm.usize, @alignCast(@ptrCast(&memory[@intCast(inputs[7].val.i32)]))),
        .stderr_len = @as(*wasm.usize, @alignCast(@ptrCast(&memory[@intCast(inputs[8].val.i32)]))),
        .term_tag = @as(*u8, &memory[@intCast(inputs[9].val.i32)]),
        .term_code = @as(*u32, @alignCast(@ptrCast(&memory[@intCast(inputs[10].val.i32)]))),
    };

    var exec_args = .{
        .allocator = self.allocator,
        .argv = blk: {
            var argv = try self.allocator.alloc([]const u8, params.argc);
            for (argv, 0..) |*arg, i| arg.* = wasm.span(memory, params.argv_ptr[i]);
            break :blk argv;
        },
        .env_map = if (params.env_map) |env_array| blk: {
            // XXX build a HashMap instead and directly init an EnvMap with that
            // so that it can directly point to the memory spans, no copying
            var env_map = std.process.EnvMap.init(self.allocator);
            var i: usize = 0;
            while (i < params.env_map_len) : (i += 2) try env_map.put(
                wasm.span(memory, env_array[i]),
                wasm.span(memory, env_array[i + 1]),
            );
            break :blk &env_map;
        } else null,
        .max_output_bytes = params.max_output_bytes,
        .expand_arg0 = params.expand_arg0,
    };
    defer self.allocator.free(exec_args.argv);
    defer if (exec_args.env_map) |m| m.deinit();

    const result = std.process.Child.exec(exec_args) catch |err| {
        inline for (std.meta.tags(@TypeOf(err)), 1..) |err_tag, i| {
            if (err == err_tag) outputs[0] = .{ .val = .{ .i32 = i } };
        }
        return;
    };

    params.stdout_len.* = @intCast(result.stdout.len);
    params.stderr_len.* = @intCast(result.stderr.len);

    {
        const output = params.output_ptr[0..params.max_output_bytes];
        @memcpy(output[0..result.stdout.len], result.stdout);
        @memcpy(output[result.stdout.len .. result.stdout.len + result.stderr.len], result.stderr);
    }

    params.term_tag.* = switch (result.term) {
        .Exited => 0,
        .Signal => 1,
        .Stopped => 2,
        .Unknown => 3,
    };
    params.term_code.* = switch (result.term) {
        .Exited => |c| @intCast(c),
        .Signal => |c| @intCast(c),
        .Stopped => |c| @intCast(c),
        .Unknown => |c| @intCast(c),
    };

    outputs[0] = .{ .val = .{ .i32 = 0 } };
}
