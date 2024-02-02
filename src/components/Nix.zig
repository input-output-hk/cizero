const builtin = @import("builtin");
const std = @import("std");
const zqlite = @import("zqlite");

const lib = @import("lib");
const meta = lib.meta;
const wasm = lib.wasm;

const components = @import("../components.zig");
const fs = @import("../fs.zig");
const sql = @import("../sql.zig");

const Registry = @import("../Registry.zig");
const Runtime = @import("../Runtime.zig");

pub const name = "nix";

const log_scope = .nix;
const log = std.log.scoped(log_scope);

allocator: std.mem.Allocator,

registry: *const Registry,

build_hook: []const u8,

builds_mutex: std.Thread.Mutex = .{},
builds: std.DoublyLinkedList(Build) = .{},

loop_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
loop_wait: std.Thread.ResetEvent = .{},

mock_lock_flake_url: if (builtin.is_test) ?meta.Closure(fn (
    allocator: std.mem.Allocator,
    flake_url: []const u8,
) LockFlakeUrlError![]const u8, true) else void = if (builtin.is_test) null,
mock_start_build_loop: if (builtin.is_test) ?meta.Closure(fn (
    allocator: std.mem.Allocator,
    flake_url: []const u8,
) (std.Thread.SpawnError || std.Thread.SetNameError || std.mem.Allocator.Error)!bool, true) else void = if (builtin.is_test) null,

const Build = struct {
    flake_url: []const u8,
    output_spec: []const u8,
    instantiation: Instantiation,
    thread: std.Thread,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.flake_url);
        self.instantiation.deinit();

        // `output_spec` is a slice of `flake_url`
    }
};

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

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef) {
    return meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef), allocator, .{
        .nix_build = Runtime.HostFunctionDef{
            .signature = .{
                .params = &.{ .i32, .i32, .i32, .i32 },
                .returns = &.{},
            },
            .host_function = Runtime.HostFunction.init(nixBuild, self),
        },
    });
}

fn nixBuild(self: *@This(), plugin_name: []const u8, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 4);
    std.debug.assert(outputs.len == 0);

    try components.rejectIfStopped(&self.loop_run);

    const params = .{
        .func_name = wasm.span(memory, inputs[0]),
        .user_data_ptr = @as([*]const u8, @ptrCast(&memory[@intCast(inputs[1].i32)])),
        .user_data_len = @as(wasm.usize, @intCast(inputs[2].i32)),
        .flake_url = wasm.span(memory, inputs[3]),
    };

    const flake_url_locked = try self.lockFlakeUrl(params.flake_url);
    errdefer self.allocator.free(flake_url_locked);

    if (!std.mem.eql(u8, params.flake_url, flake_url_locked))
        log.debug("locked flake URL {s} to {s}", .{ params.flake_url, flake_url_locked });

    {
        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        try conn.transaction();
        errdefer conn.rollback();

        try sql.queries.callback.insert.exec(conn, .{
            plugin_name,
            params.func_name,
            if (params.user_data_len != 0) .{ .value = params.user_data_ptr[0..params.user_data_len] } else null,
        });
        try sql.queries.nix_callback.insert.exec(conn, .{
            conn.lastInsertedRowId(),
            flake_url_locked,
        });

        try conn.commit();
    }

    const started = try self.startBuildLoop(flake_url_locked);
    if (!started) self.allocator.free(flake_url_locked);
}

pub const LockFlakeUrlError =
    error{CouldNotLockFlake} ||
    std.mem.Allocator.Error ||
    std.process.Child.RunError ||
    std.json.ParseError(std.json.Scanner);

fn lockFlakeUrl(self: @This(), flake_url: []const u8) LockFlakeUrlError![]const u8 {
    if (comptime @TypeOf(self.mock_lock_flake_url) != void)
        if (self.mock_lock_flake_url) |mock|
            return mock.call(.{ self.allocator, flake_url });

    const flake_base_url = std.mem.sliceTo(flake_url, '#');

    const result = try std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = &.{
            "nix",
            "flake",
            "metadata",
            "--json",
            flake_base_url,
        },
    });
    defer {
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
    }

    if (result.term != .Exited or result.term.Exited != 0) {
        log.debug("Could not lock {s}: {}\n{s}", .{ flake_url, result.term, result.stderr });
        return error.CouldNotLockFlake; // TODO return proper error to plugin caller
    }

    const metadata = try std.json.parseFromSlice(struct {
        lockedUrl: ?[]const u8 = null,
        url: ?[]const u8 = null,
    }, self.allocator, result.stdout, .{
        .ignore_unknown_fields = true,
    });
    defer metadata.deinit();

    // As of Nix 2.18.1, the man page says
    // the key should be called `lockedUrl`,
    // but it is actually called just `url`.
    const locked_url = metadata.value.lockedUrl orelse metadata.value.url.?;

    return std.mem.concat(self.allocator, u8, &.{ locked_url, flake_url[flake_base_url.len..] });
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

pub fn start(self: *@This()) (std.Thread.SpawnError || std.Thread.SetNameError || zqlite.Error)!std.Thread {
    self.loop_run.store(true, .Monotonic);
    self.loop_wait.reset();

    const thread = try std.Thread.spawn(.{}, loop, .{self});
    thread.setName(name) catch |err| log.debug("could not set thread name: {s}", .{@errorName(err)});

    {
        const SelectPending = sql.queries.nix_callback.Select(&.{.flake_url});
        var rows = blk: {
            const conn = self.registry.db_pool.acquire();
            defer self.registry.db_pool.release(conn);

            break :blk try SelectPending.rows(conn, .{});
        };
        errdefer rows.deinit();
        while (rows.next()) |row| {
            const flake_url = try self.allocator.dupe(u8, SelectPending.column(row, .flake_url));
            errdefer self.allocator.free(flake_url);

            const started = try self.startBuildLoop(flake_url);
            if (!started) self.allocator.free(flake_url);
        }
        try rows.deinitErr();
    }

    return thread;
}

pub fn stop(self: *@This()) void {
    self.loop_run.store(false, .Monotonic);
    self.loop_wait.set();
}

fn loop(self: *@This()) !void {
    while (self.loop_run.load(.Monotonic) or self.builds.len != 0) : (self.loop_wait.reset()) {
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

/// Returns whether a new build loop thread has been started.
/// If true, takes ownership of the `flake_url` parameter, otherwise not.
fn startBuildLoop(self: *@This(), flake_url: []const u8) (std.Thread.SpawnError || std.Thread.SetNameError || std.mem.Allocator.Error)!bool {
    if (comptime @TypeOf(self.mock_start_build_loop) != void)
        if (self.mock_start_build_loop) |mock| return mock.call(.{
            self.allocator,
            flake_url,
        });

    {
        self.builds_mutex.lock();
        defer self.builds_mutex.unlock();

        var node = self.builds.first;
        while (node != null) : (node = node.?.next) {
            if (!std.mem.eql(u8, node.?.data.flake_url, flake_url)) continue;

            log.debug("build loop is already running for {s}", .{flake_url});
            return false;
        }
    }

    log.debug("starting build loop for {s}", .{flake_url});

    const node = try self.allocator.create(@TypeOf(self.builds).Node);
    errdefer self.allocator.destroy(node);

    node.data = .{
        .flake_url = flake_url,
        .output_spec = flake_url[if (std.mem.indexOfScalar(u8, flake_url, '^')) |i| i + 1 else flake_url.len..],
        .instantiation = .{ .ifds = std.BufSet.init(self.allocator) },
        .thread = try std.Thread.spawn(.{}, buildLoop, .{ self, node }),
    };

    {
        self.builds_mutex.lock();
        defer self.builds_mutex.unlock();

        self.builds.append(node);

        log.debug("number of builds grew to {d}", .{self.builds.len});
    }

    node.data.thread.setName(thread_name: {
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
    }) catch |err| log.debug("could not set thread name: {s}", .{@errorName(err)});

    return true;
}

fn buildLoop(self: *@This(), node: *std.DoublyLinkedList(Build).Node) !void {
    log.debug("entered build loop for {s}", .{node.data.flake_url});

    defer {
        node.data.deinit(self.allocator);

        self.loop_wait.set();
        std.Thread.yield() catch {};
    }

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

                try self.runCallbacks(node.data, if (outputs.len != 0) .{ .outputs = outputs } else .{ .failed_drv = drv.items });
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

                        try self.runCallbacks(node.data, .{ .failed_drv = ifd.* });
                        break :instantiate;
                    }
                }
            },
        }
    }
}

fn runCallbacks(self: *@This(), build_state: Build, result: union(enum) {
    outputs: []const []const u8,
    failed_drv: []const u8,
}) !void {
    const SelectCallback = sql.queries.nix_callback.SelectCallbackByFlakeUrl(&.{ .id, .plugin, .function, .user_data });
    var callback_rows = blk: {
        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        break :blk try SelectCallback.rows(conn, .{build_state.flake_url});
    };
    errdefer callback_rows.deinit();

    while (callback_rows.next()) |callback_row| {
        var runtime = try self.registry.runtime(SelectCallback.column(callback_row, .plugin));
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

        var callback: components.CallbackUnmanaged = undefined;
        try sql.structFromRow(self.allocator, &callback, callback_row, SelectCallback.column, .{
            .func_name = .function,
            .user_data = .user_data,
        });
        defer callback.deinit(self.allocator);

        _ = try callback.run(self.allocator, runtime, &[_]wasm.Value{
            .{ .i32 = @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, build_state.flake_url)).ptr)) },
            .{ .i32 = if (result == .outputs) @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, build_state.instantiation.drv.items)).ptr)) else 0 },
            .{ .i32 = if (outputs) |outs| @intCast(linear.memory.offset(outs.ptr)) else 0 },
            .{ .i32 = if (outputs) |outs| @intCast(outs.len) else 0 },
            .{ .i32 = switch (result) {
                .outputs => 0,
                .failed_drv => |dep| @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, dep)).ptr)),
            } },
        }, &.{});

        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        try sql.queries.callback.deleteById.exec(conn, .{SelectCallback.column(callback_row, .id)});
    }

    try callback_rows.deinitErr();
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

        const result = try std.process.Child.run(.{
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

    const result = try std.process.Child.run(.{
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
    errdefer {
        for (outputs.items) |output| allocator.free(output);
        outputs.deinit(allocator);
    }
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
