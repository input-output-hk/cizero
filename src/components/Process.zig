const builtin = @import("builtin");
const std = @import("std");

const lib = @import("lib");
const meta = lib.meta;
const wasm = lib.wasm;

const Plugin = @import("../Plugin.zig");

pub const name = "process";

const log = std.log.scoped(.process);

allocator: std.mem.Allocator,

mock_child_run: if (builtin.is_test) ?meta.Closure(@TypeOf(std.process.Child.run), true) else void = if (builtin.is_test) null,

fn childRun(
    self: @This(),
    args: @typeInfo(@TypeOf(std.process.Child.run)).Fn.params[0].type.?,
) @typeInfo(@TypeOf(std.process.Child.run)).Fn.return_type.? {
    if (@TypeOf(self.mock_child_run) != void)
        if (self.mock_child_run) |mock| return mock.call(.{args});
    return std.process.Child.run(args);
}

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    return meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef), allocator, .{
        .exec = Plugin.Runtime.HostFunctionDef{
            .signature = .{
                .params = &[_]wasm.Value.Type{.i32} ** 11,
                .returns = &.{.i32},
            },
            .host_function = Plugin.Runtime.HostFunction.init(exec, self),
        },
    });
}

fn exec(self: *@This(), _: Plugin, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 11);
    std.debug.assert(outputs.len == 1);

    const params = .{
        .argv_ptr = @as([*]const wasm.usize, @alignCast(@ptrCast(&memory[@intCast(inputs[0].i32)]))),
        .argc = @as(wasm.usize, @intCast(inputs[1].i32)),
        .expand_arg0 = @as(std.process.Child.Arg0Expand, switch (inputs[2].i32) {
            1 => .expand,
            0 => .no_expand,
            else => unreachable,
        }),
        .env_map = @as(?[*]const wasm.usize, @alignCast(@ptrCast(&memory[@intCast(inputs[3].i32)]))),
        .env_map_len = @as(wasm.usize, @intCast(inputs[4].i32)),
        .max_output_bytes = @as(wasm.usize, @intCast(inputs[5].i32)),
        .output_ptr = @as([*]u8, @ptrCast(&memory[@intCast(inputs[6].i32)])),
        .stdout_len = @as(*wasm.usize, @alignCast(@ptrCast(&memory[@intCast(inputs[7].i32)]))),
        .stderr_len = @as(*wasm.usize, @alignCast(@ptrCast(&memory[@intCast(inputs[8].i32)]))),
        .term_tag = @as(*u8, &memory[@intCast(inputs[9].i32)]),
        .term_code = @as(*u32, @alignCast(@ptrCast(&memory[@intCast(inputs[10].i32)]))),
    };

    var exec_args = .{
        .allocator = self.allocator,
        .argv = blk: {
            const argv = try self.allocator.alloc([]const u8, params.argc);
            for (argv, params.argv_ptr) |*arg, argv_ptr| arg.* = wasm.span(memory, argv_ptr);
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

    const result = @call(.auto, childRun, .{ self.*, exec_args }) catch |err| {
        const E = std.process.Child.RunError;

        const err_tags = try self.allocator.dupe(E, std.meta.tags(E));
        defer self.allocator.free(err_tags);

        std.mem.sortUnstable(E, err_tags, {}, struct {
            fn call(_: void, lhs: E, rhs: E) bool {
                return std.mem.order(u8, @errorName(lhs), @errorName(rhs)) == .lt;
            }
        }.call);

        for (err_tags, 1..) |err_tag, i| {
            if (err != err_tag) continue;
            outputs[0] = .{ .i32 = @intCast(i) };
            return;
        }
        unreachable;
    };
    defer {
        exec_args.allocator.free(result.stdout);
        exec_args.allocator.free(result.stderr);
    }
    log.debug("process {s} terminated with {}", .{ exec_args.argv, result.term });

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

    outputs[0] = .{ .i32 = 0 };
}
