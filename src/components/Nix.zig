const std = @import("std");

const components = @import("../components.zig");
const fs = @import("../fs.zig");
const meta = @import("../meta.zig");
const wasm = @import("../wasm.zig");

const Plugin = @import("../Plugin.zig");
const Registry = @import("../Registry.zig");

pub const name = "nix";

const log_scope = .nix;
const log = std.log.scoped(log_scope);

allocator: std.mem.Allocator,

registry: *const Registry,

build_hook: []const u8,

builds_mutex: std.Thread.Mutex = .{},
builds: std.DoublyLinkedList(Build) = .{},

loop_run: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(true),
loop_wait: std.Thread.ResetEvent = .{},

lock_flake_url_closure: meta.Closure(@TypeOf(lockFlakeUrl), true) = meta.disclosure(lockFlakeUrl, true),
mock_start_build_loop: ?meta.Closure(fn (
    allocator: std.mem.Allocator,
    flake_url: []const u8,
    plugin_name: []const u8,
    callback: Callback,
) (std.Thread.SpawnError || std.Thread.SetNameError || std.mem.Allocator.Error)!void, true) = null,

const Build = struct {
    flake_url: []const u8,
    output_spec: []const u8,
    instantiation: Instantiation,
    plugin_name: []const u8,
    callback: Callback,
    thread: std.Thread,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.flake_url);
        self.instantiation.deinit();
        self.callback.deinit(allocator);

        // `output_spec` is a slice of `flake_url`
        // `plugin_name` is borrowed
    }
};

pub const Callback = components.CallbackUnmanaged(struct {
    pub fn done(_: @This()) components.CallbackDoneCondition {
        return .always;
    }
});

pub fn deinit(self: *@This()) void {
    self.allocator.free(self.build_hook);
}

pub const InitError = std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator, registry: *const Registry) InitError!@This() {
    return .{
        .allocator = allocator,
        .registry = registry,
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
                .params = &.{ .i32, .i32, .i32, .i32 },
                .returns = &.{},
            },
            .host_function = Plugin.Runtime.HostFunction.init(nixBuild, self),
        },
    });
}

fn nixBuild(self: *@This(), plugin: Plugin, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 4);
    std.debug.assert(outputs.len == 0);

    const params = .{
        .func_name = wasm.span(memory, inputs[0]),
        .user_data_ptr = @as([*]const u8, @ptrCast(&memory[@intCast(inputs[1].i32)])),
        .user_data_len = @as(wasm.usize, @intCast(inputs[2].i32)),
        .flake_url = wasm.span(memory, inputs[3]),
    };

    const flake_url_locked = try self.lock_flake_url_closure.call(.{ self.allocator, params.flake_url });
    errdefer self.allocator.free(flake_url_locked);

    if (!std.mem.eql(u8, params.flake_url, flake_url_locked))
        log.debug("locked flake URL {s} to {s}", .{ params.flake_url, flake_url_locked });

    try self.startBuildLoop(
        flake_url_locked,
        plugin.name(),
        try Callback.init(
            self.allocator,
            params.func_name,
            if (params.user_data_len != 0) params.user_data_ptr[0..params.user_data_len] else null,
            .{},
        ),
    );
}

fn lockFlakeUrl(allocator: std.mem.Allocator, flake_url: []const u8) ![]const u8 {
    const flake_base_url = std.mem.sliceTo(flake_url, '#');

    const result = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &.{
            "nix",
            "flake",
            "metadata",
            "--json",
            flake_base_url,
        },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term != .Exited or result.term.Exited != 0) {
        log.debug("Could not lock {s}: {}\n{s}", .{ flake_url, result.term, result.stderr });
        return error.CouldNotLockFlake; // TODO return proper error to plugin caller
    }

    const metadata = try std.json.parseFromSlice(struct {
        lockedUrl: ?[]const u8 = null,
        url: ?[]const u8 = null,
    }, allocator, result.stdout, .{
        .ignore_unknown_fields = true,
    });
    defer metadata.deinit();

    // As of Nix 2.18.1, the man page says
    // the key should be called `lockedUrl`,
    // but it is actually called just `url`.
    const locked_url = metadata.value.lockedUrl orelse metadata.value.url.?;

    return std.mem.concat(allocator, u8, &.{ locked_url, flake_url[flake_base_url.len..] });
}

test lockFlakeUrl {
    // this test spawns a child process and needs internet
    if (true) return error.SkipZigTest;

    const latest = "github:NixOS/nixpkgs";
    const input = latest ++ "/23.11";
    const expected = latest ++ "/057f9aecfb71c4437d2b27d3323df7f93c010b7e";

    {
        const locked = try lockFlakeUrl(std.testing.allocator, input);
        defer std.testing.allocator.free(locked);

        try std.testing.expectEqualStrings(expected, locked);
    }

    {
        const locked = try lockFlakeUrl(std.testing.allocator, input ++ "#hello^out");
        defer std.testing.allocator.free(locked);

        try std.testing.expectEqualStrings(expected ++ "#hello^out", locked);
    }
}

pub fn start(self: *@This()) (std.Thread.SpawnError || std.Thread.SetNameError)!std.Thread {
    const thread = try std.Thread.spawn(.{}, loop, .{self});
    try thread.setName(name);
    return thread;
}

/// Cannot be started again once stopped.
pub fn stop(self: *@This()) void {
    self.loop_run.store(false, .Monotonic);
    self.loop_wait.set();
}

fn loop(self: *@This()) !void {
    while (self.loop_run.load(.Monotonic)) : (self.loop_wait.reset()) {
        if (self.builds.first) |node| {
            node.data.thread.join();

            {
                self.builds_mutex.lock();
                defer self.builds_mutex.unlock();

                self.builds.remove(node);

                log.debug("number of builds shrank to {d}", .{self.builds.len});
            }

            self.allocator.destroy(node);
        } else self.loop_wait.wait();
    }
}

fn startBuildLoop(
    self: *@This(),
    flake_url: []const u8,
    plugin_name: []const u8,
    callback: Callback,
) (std.Thread.SpawnError || std.Thread.SetNameError || std.mem.Allocator.Error)!void {
    if (self.mock_start_build_loop) |mock| return mock.call(.{
        self.allocator,
        flake_url,
        plugin_name,
        callback,
    });

    const node = try self.allocator.create(@TypeOf(self.builds).Node);
    node.data = .{
        .flake_url = flake_url,
        .output_spec = flake_url[if (std.mem.indexOfScalar(u8, flake_url, '^')) |i| i + 1 else flake_url.len..],
        .instantiation = .{ .ifds = std.BufSet.init(self.allocator) },
        .plugin_name = plugin_name,
        .callback = callback,
        .thread = try std.Thread.spawn(.{}, buildLoop, .{ self, node }),
    };

    {
        self.builds_mutex.lock();
        defer self.builds_mutex.unlock();

        self.builds.append(node);

        log.debug("number of builds grew to {d}", .{self.builds.len});
    }

    try node.data.thread.setName(thread_name: {
        var thread_name_buf: [std.Thread.max_name_len]u8 = undefined;

        const prefix = name ++ ": ";
        const prefix_len: usize = @min(prefix.len, std.Thread.max_name_len);

        @memcpy(thread_name_buf[0..prefix_len], prefix[0..prefix_len]);

        const name_len = if (prefix_len != std.Thread.max_name_len) len: {
            const flake_url_len = std.Thread.max_name_len - prefix_len;
            @memcpy(thread_name_buf[prefix_len..], flake_url[0..flake_url_len]);
            break :len prefix_len + flake_url_len;
        } else prefix_len;

        const thread_name = thread_name_buf[0..name_len];

        if (thread_name.len == std.Thread.max_name_len) {
            const ellip = "...";
            @memcpy(thread_name[thread_name.len - ellip.len ..], ellip);
        }

        log.debug("spawned thread: {s}", .{thread_name});

        break :thread_name thread_name;
    });
}

fn buildLoop(self: *@This(), node: *std.DoublyLinkedList(Build).Node) !void {
    log.debug("entered build loop for {s}", .{node.data.flake_url});

    defer node.data.deinit(self.allocator);

    instantiate: while (true) {
        log.debug("instantiating {s}", .{node.data.flake_url});

        const instantiation = try instantiate(
            self.allocator,
            self.build_hook,
            node.data.flake_url,
        );
        node.data.instantiation.deinit();
        node.data.instantiation = instantiation;

        switch (instantiation) {
            .drv => |drv| {
                const outputs = try build(self.allocator, drv.items, node.data.output_spec);
                defer {
                    for (outputs) |output| self.allocator.free(output);
                    self.allocator.free(outputs);
                }

                log.debug("built {s} as {s} producing {s}", .{ node.data.flake_url, drv.items, outputs });

                try self.runCallback(node.data, if (outputs.len != 0) .{ .outputs = outputs } else .{ .failed_drv = drv.items });
                break;
            },
            .ifds => |ifds| {
                var iter = ifds.iterator();
                while (iter.next()) |ifd| {
                    const outputs = try build(self.allocator, ifd.*, node.data.output_spec);
                    defer {
                        for (outputs) |output| self.allocator.free(output);
                        self.allocator.free(outputs);
                    }

                    log.debug("built {s} IFD {s} producing {s}", .{ node.data.flake_url, ifd.*, outputs });

                    if (outputs.len == 0) {
                        log.debug("could not build {s} due to failure building IFD {s}", .{ node.data.flake_url, ifd.* });

                        try self.runCallback(node.data, .{ .failed_drv = ifd.* });
                        break :instantiate;
                    }
                }
            },
        }
    }
}

fn runCallback(self: *@This(), build_state: Build, result: union(enum) {
    outputs: []const []const u8,
    failed_drv: []const u8,
}) !void {
    var runtime = try self.registry.runtime(build_state.plugin_name);
    defer runtime.deinit();

    const linear = try runtime.linearMemoryAllocator();
    const linear_allocator = linear.allocator();

    const outputs = switch (result) {
        .failed_drv => null,
        .outputs => |result_outputs| blk: {
            const addrs = try linear_allocator.alloc(wasm.usize, result_outputs.len);
            for (result_outputs, addrs) |result_output, *addr| {
                const out = try linear_allocator.dupeZ(u8, result_output);
                addr.* = linear.memory.offset(out.ptr);
            }
            break :blk addrs;
        },
    };

    _ = try build_state.callback.run(self.allocator, runtime, &[_]wasm.Value{
        .{ .i32 = @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, build_state.flake_url)).ptr)) },
        .{ .i32 = if (result == .outputs) @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, build_state.instantiation.drv.items)).ptr)) else 0 },
        .{ .i32 = if (outputs) |outs| @intCast(linear.memory.offset(outs.ptr)) else 0 },
        .{ .i32 = if (outputs) |outs| @intCast(outs.len) else 0 },
        .{ .i32 = switch (result) {
            .outputs => 0,
            .failed_drv => |dep| @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, dep)).ptr)),
        } },
    }, &.{});
}

const Instantiation = union(enum) {
    drv: std.ArrayList(u8),
    ifds: std.BufSet,

    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            inline else => |*case| case.deinit(),
        }
    }
};

fn instantiate(allocator: std.mem.Allocator, build_hook: []const u8, flake_url: []const u8) !Instantiation {
    const ifds_tmp = try fs.tmpFile(allocator, .{ .read = true });
    defer ifds_tmp.deinit(allocator);

    {
        const args = .{
            "nix",
            "eval",
            "--restrict-eval",
            "--allow-import-from-derivation",
            "--build-hook",
            build_hook,
            "--max-jobs",
            "0",
            "--builders",
            ifds_tmp.path,
            "--apply",
            "drv: drv.drvPath or drv",
            "--raw",
            "--verbose",
            "--trace-verbose",
            flake_url,
        };

        const result = try std.process.Child.exec(.{
            .allocator = allocator,
            .argv = &args,
        });
        defer allocator.free(result.stderr);

        if (result.term == .Exited and result.term.Exited == 0) {
            return .{ .drv = std.ArrayList(u8).fromOwnedSlice(allocator, result.stdout) };
        } else {
            log.debug("command {s} terminated with {}\n{s}", .{ @as([]const []const u8, &args), result.term, result.stderr });
            allocator.free(result.stdout);
        }
    }

    var ifds = std.BufSet.init(allocator);
    errdefer ifds.deinit();

    {
        const ifds_tmp_reader = ifds_tmp.file.reader();

        var ifd = std.ArrayListUnmanaged(u8){};
        defer ifd.deinit(allocator);

        const ifd_writer = ifd.writer(allocator);

        while (ifds_tmp_reader.streamUntilDelimiter(ifd_writer, '\n', null) != error.EndOfStream) : (ifd.clearRetainingCapacity())
            try ifds.insert(ifd.items);
    }

    if (comptime std.log.logEnabled(.debug, log_scope)) {
        var iter = ifds.iterator();
        while (iter.next()) |ifd| log.debug("found IFD: {s}", .{ifd.*});
    }

    return .{ .ifds = ifds };
}

/// Returns the outputs.
fn build(allocator: std.mem.Allocator, store_drv: []const u8, output_spec: []const u8) ![]const []const u8 {
    const installable = try std.mem.concat(allocator, u8, &.{
        store_drv,
        "^",
        if (output_spec.len == 0) "out" else output_spec,
    });
    defer allocator.free(installable);

    log.debug("building {s}", .{installable});

    const result = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &.{
            "nix",
            "build",
            "--restrict-eval",
            "--no-link",
            "--print-out-paths",
            "--verbose",
            "--trace-verbose",
            installable,
        },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term != .Exited or result.term.Exited != 0) {
        log.debug("build of {s} failed: {s}", .{ store_drv, result.stderr });
        return &.{};
    }

    var outputs = std.ArrayListUnmanaged([]const u8){};
    {
        var iter = std.mem.tokenizeScalar(u8, result.stdout, '\n');
        while (iter.next()) |output|
            try outputs.append(allocator, try allocator.dupe(u8, output));
    }
    return outputs.toOwnedSlice(allocator);
}

test {
    _ = @import("nix/build-hook/main.zig");
}
