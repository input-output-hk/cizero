const std = @import("std");

const meta = @import("../meta.zig");
const wasm = @import("../wasm.zig");

const Plugin = @import("../Plugin.zig");

pub const name = "nix";

allocator: std.mem.Allocator,

build_hook: []const u8,

pub fn deinit(self: @This()) void {
    self.allocator.free(self.build_hook);
}

pub const InitError = std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator) InitError!@This() {
    return .{
        .allocator = allocator,
        .build_hook = blk: {
            var args = try std.process.argsWithAllocator(allocator);
            defer args.deinit();

            break :blk try std.fs.path.join(allocator, &.{
                std.fs.path.dirname(args.next().?).?,
                "..",
                "libexec",
                "cizero",
                "components",
                name,
                "build-hook",
            });
        },
    };
}

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    return meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef), allocator, .{
        .nix_build = Plugin.Runtime.HostFunctionDef{
            .signature = .{
                .params = &[_]wasm.Value.Type{.i32} ** 0,
                .returns = &.{},
            },
            .host_function = Plugin.Runtime.HostFunction.init(nixBuild, self),
        },
    });
}

fn nixBuild(self: *@This(), _: Plugin, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    _ = memory;
    _ = self;

    std.debug.assert(inputs.len == 0);
    std.debug.assert(outputs.len == 0);
}

test {
    _ = @import("nix/build-hook/main.zig");
}
