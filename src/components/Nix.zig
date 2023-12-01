const std = @import("std");

const fs = @import("../fs.zig");
const meta = @import("../meta.zig");
const wasm = @import("../wasm.zig");

const Plugin = @import("../Plugin.zig");

pub const name = "nix";

const log = std.log.scoped(.nix);

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
                .params = &.{ .i32, .i32, .i32 },
                .returns = &.{},
            },
            .host_function = Plugin.Runtime.HostFunction.init(nixBuild, self),
        },
    });
}

fn nixBuild(self: *@This(), _: Plugin, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 3);
    std.debug.assert(outputs.len == 0);

    const params = .{
        .flake_url = wasm.span(memory, inputs[0]),
        .args_ptr = @as([*]const wasm.usize, @alignCast(@ptrCast(&memory[@intCast(inputs[1].i32)]))),
        .args_len = @as(wasm.usize, @intCast(inputs[2].i32)),
    };

    const ifds_tmp = try fs.tmpFile(self.allocator, .{ .read = true });
    defer ifds_tmp.deinit(self.allocator);

    {
        var extra_args = try self.allocator.alloc([]const u8, params.args_len);
        defer self.allocator.free(extra_args);
        for (extra_args, 0..) |*arg, i| arg.* = wasm.span(memory, params.args_ptr[i]);

        var args = try std.mem.concat(self.allocator, []const u8, &.{ &.{
            "nix",
            "eval",
        }, extra_args, &.{
            "--allow-import-from-derivation",
            "--build-hook",
            self.build_hook,
            "--max-jobs",
            "0",
            "--builders",
            ifds_tmp.path,
            "--apply",
            "drv: drv.drvPath or drv",
            "--raw",
            "--verbose",
            "--trace-verbose",
            params.flake_url,
        } });
        defer self.allocator.free(args);

        var child = std.process.Child.init(args, self.allocator);
        try child.spawn();
        const term = try child.wait();

        log.debug("command {s} terminated with {}\n", .{ args, term });
    }

    var ifds = std.BufSet.init(self.allocator);
    defer ifds.deinit();

    {
        const ifds_tmp_reader = ifds_tmp.file.reader();

        var ifd = std.ArrayListUnmanaged(u8){};
        defer ifd.deinit(self.allocator);

        const ifd_writer = ifd.writer(self.allocator);

        while (ifds_tmp_reader.streamUntilDelimiter(ifd_writer, '\n', null) != error.EndOfStream) : (ifd.clearRetainingCapacity())
            try ifds.insert(ifd.items);
    }

    {
        var iter = ifds.iterator();
        while (iter.next()) |ifd| log.debug("found IFD: {s}", .{ifd.*});
    }
}

test {
    _ = @import("nix/build-hook/main.zig");
}
