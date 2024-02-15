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

jobs_mutex: std.Thread.Mutex = .{},
jobs: std.HashMapUnmanaged(Job, Eval, struct {
    pub fn hash(_: @This(), key: Job) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key, .Deep);
        return hasher.final();
    }

    pub fn eql(_: @This(), a: Job, b: Job) bool {
        return std.mem.eql(u8, a.flake_url, b.flake_url) and
            std.mem.eql(u8, a.expression orelse "", b.expression orelse "") and
            a.build == b.build;
    }
}, std.hash_map.default_max_load_percentage) = .{},

job_threads_mutex: std.Thread.Mutex = .{},
job_threads: std.DoublyLinkedList(std.Thread) = .{},

loop_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
loop_wait: std.Thread.ResetEvent = .{},

mock_lock_flake_url: if (builtin.is_test) ?meta.Closure(fn (
    allocator: std.mem.Allocator,
    flake_url: []const u8,
) LockFlakeUrlError![]const u8, true) else void = if (builtin.is_test) null,
mock_start_job_loop: if (builtin.is_test) ?meta.Closure(fn (
    allocator: std.mem.Allocator,
    job: Job,
) (std.Thread.SpawnError || std.Thread.SetNameError || std.mem.Allocator.Error)!bool, true) else void = if (builtin.is_test) null,

pub const Job = struct {
    flake_url: []const u8,
    expression: ?[]const u8,
    build: bool,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try std.fmt.format(writer, "`nix {s} {s}{s}{s}`", .{
            if (self.build) "build" else "eval",
            self.flake_url,
            if (self.expression != null) " --apply " else "",
            self.expression orelse "",
        });
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.flake_url);
        if (self.expression) |e| allocator.free(e);
    }
};

pub fn deinit(self: *@This()) void {
    self.allocator.free(self.build_hook);

    {
        var iter = self.jobs.iterator();
        while (iter.next()) |entry| {
            entry.key_ptr.deinit(self.allocator);
            entry.value_ptr.deinit();
        }
        self.jobs.deinit(self.allocator);
    }
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
        .nix_eval = Runtime.HostFunctionDef{
            .signature = .{
                .params = &.{ .i32, .i32, .i32, .i32, .i32 },
                .returns = &.{},
            },
            .host_function = Runtime.HostFunction.init(nixEval, self),
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

    const job = Job{
        .flake_url = try self.lockFlakeUrl(params.flake_url),
        .expression = null,
        .build = true,
    };
    errdefer job.deinit(self.allocator);

    try self.insertCallback(plugin_name, params.func_name, params.user_data_ptr, params.user_data_len, job);

    const started = try self.startJobLoop(job);
    if (!started) job.deinit(self.allocator);
}

fn nixEval(self: *@This(), plugin_name: []const u8, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 5);
    std.debug.assert(outputs.len == 0);

    try components.rejectIfStopped(&self.loop_run);

    const params = .{
        .func_name = wasm.span(memory, inputs[0]),
        .user_data_ptr = @as([*]const u8, @ptrCast(&memory[@intCast(inputs[1].i32)])),
        .user_data_len = @as(wasm.usize, @intCast(inputs[2].i32)),
        .flake_url = wasm.span(memory, inputs[3]),
        .expression = if (inputs[4].i32 != 0) wasm.span(memory, inputs[4]) else null,
    };

    const job = job: {
        const flake_url = try self.lockFlakeUrl(params.flake_url);
        errdefer self.allocator.free(flake_url);

        const expression = if (params.expression) |expression| try self.allocator.dupe(u8, expression) else null;
        errdefer if (expression) |e| self.allocator.free(e);

        break :job Job{
            .flake_url = flake_url,
            .expression = expression,
            .build = false,
        };
    };
    errdefer job.deinit(self.allocator);

    try self.insertCallback(plugin_name, params.func_name, params.user_data_ptr, params.user_data_len, job);

    const started = try self.startJobLoop(job);
    if (!started) job.deinit(self.allocator);
}

fn insertCallback(
    self: @This(),
    plugin_name: []const u8,
    func_name: []const u8,
    user_data_ptr: [*]const u8,
    user_data_len: wasm.usize,
    job: Job,
) !void {
    const conn = self.registry.db_pool.acquire();
    defer self.registry.db_pool.release(conn);

    try conn.transaction();
    errdefer conn.rollback();

    try sql.queries.callback.insert.exec(conn, .{
        plugin_name,
        func_name,
        if (user_data_len != 0) .{ .value = user_data_ptr[0..user_data_len] } else null,
    });
    try sql.queries.nix_callback.insert.exec(conn, .{
        conn.lastInsertedRowId(),
        job.flake_url,
        job.expression,
        job.build,
    });

    try conn.commit();
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
            "--refresh",
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
    const locked_base_url = metadata.value.lockedUrl orelse metadata.value.url.?;

    const locked_flake_url = try std.mem.concat(self.allocator, u8, &.{ locked_base_url, flake_url[flake_base_url.len..] });

    if (comptime std.log.logEnabled(.debug, log_scope)) {
        if (std.mem.eql(u8, locked_flake_url, flake_url))
            log.debug("flake URL {s} is already locked", .{flake_url})
        else
            log.debug("flake URL {s} locked to {s}", .{ flake_url, locked_flake_url });
    }

    return locked_flake_url;
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

fn flakeUrlOutputSpec(flake_url: []const u8) ?[]const u8 {
    return if (std.mem.indexOfScalar(u8, flake_url, '^')) |i| flake_url[i + 1 ..] else null;
}

pub fn start(self: *@This()) (std.Thread.SpawnError || std.Thread.SetNameError || zqlite.Error)!std.Thread {
    self.loop_run.store(true, .Monotonic);
    self.loop_wait.reset();

    const thread = try std.Thread.spawn(.{}, loop, .{self});
    thread.setName(name) catch |err| log.debug("could not set thread name: {s}", .{@errorName(err)});

    {
        const SelectPending = sql.queries.nix_callback.Select(&.{ .flake_url, .expression, .build });
        var rows = blk: {
            const conn = self.registry.db_pool.acquire();
            defer self.registry.db_pool.release(conn);

            break :blk try SelectPending.rows(conn, .{});
        };
        errdefer rows.deinit();
        while (rows.next()) |row| {
            const flake_url = try self.allocator.dupe(u8, SelectPending.column(row, .flake_url));
            errdefer self.allocator.free(flake_url);

            const expression = if (SelectPending.column(row, .expression)) |e| try self.allocator.dupe(u8, e) else null;
            errdefer if (expression) |e| self.allocator.free(e);

            const job = Job{
                .flake_url = flake_url,
                .expression = expression,
                .build = SelectPending.column(row, .build),
            };

            const started = try self.startJobLoop(job);
            if (!started) job.deinit(self.allocator);
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
    while (self.loop_run.load(.Monotonic) or self.job_threads.len != 0) : (self.loop_wait.reset()) {
        const first_node = blk: {
            self.job_threads_mutex.lock();
            defer self.job_threads_mutex.unlock();

            break :blk self.job_threads.popFirst();
        };

        if (first_node) |node| {
            const thread = node.data;
            self.allocator.destroy(node);
            thread.join();
        } else self.loop_wait.wait();
    }
}

/// Returns whether a new job loop thread has been started.
/// If true, takes ownership of the `job` parameter, otherwise not.
fn startJobLoop(self: *@This(), job: Job) (std.Thread.SpawnError || std.Thread.SetNameError || std.mem.Allocator.Error)!bool {
    if (comptime @TypeOf(self.mock_start_job_loop) != void)
        if (self.mock_start_job_loop) |mock| return mock.call(.{
            self.allocator,
            job,
        });

    {
        self.jobs_mutex.lock();
        defer self.jobs_mutex.unlock();

        const gop = try self.jobs.getOrPut(self.allocator, job);

        if (gop.found_existing) {
            log.debug("loop is already running for job: {}", .{job});
            return false;
        }

        log.debug("starting loop for job {}", .{job});
        gop.value_ptr.* = .{ .ifds = std.BufSet.init(self.allocator) };
    }

    const node = try self.allocator.create(@TypeOf(self.job_threads).Node);
    errdefer self.allocator.destroy(node);

    node.data = try std.Thread.spawn(.{}, jobLoop, .{ self, job, node });
    node.data.setName(name) catch |err| log.debug("could not set thread name: {s}", .{@errorName(err)});

    return true;
}

fn jobLoop(self: *@This(), job: Job, node: *@TypeOf(self.job_threads).Node) !void {
    log.debug("entered loop for job {}", .{job});

    defer {
        {
            self.job_threads_mutex.lock();
            defer self.job_threads_mutex.unlock();

            self.job_threads.prepend(node);
        }

        self.loop_wait.set();
    }

    const output_spec = flakeUrlOutputSpec(job.flake_url);

    while (true) {
        log.debug("evaluating job {}", .{job});

        var evaluation = try if (job.build) blk: {
            const apply = try std.mem.concat(
                self.allocator,
                u8,
                if (job.expression) |expression| &.{
                    \\let apply =
                    ,
                    expression,
                    \\; in
                    \\x: let result = apply x; in
                    \\x.drvPath or x
                } else &.{
                    \\drv: drv.drvPath or drv
                },
            );
            defer self.allocator.free(apply);

            break :blk self.eval(
                job.flake_url,
                apply,
                .raw,
            );
        } else self.eval(
            job.flake_url,
            job.expression,
            .json,
        );

        {
            errdefer evaluation.deinit();

            self.jobs_mutex.lock();
            defer self.jobs_mutex.unlock();

            const job_state = self.jobs.getPtr(job).?;
            job_state.deinit();
            job_state.* = evaluation;
        }

        const result: JobResult = switch (evaluation) {
            .ok => |evaluated| if (job.build) blk: {
                const outputs = try build(self.allocator, evaluated.items, output_spec);
                errdefer {
                    for (outputs) |output| self.allocator.free(output);
                    self.allocator.free(outputs);
                }

                if (outputs.len == 0) {
                    log.debug("could not build job {} as {s}", .{ job, evaluated.items });

                    self.allocator.free(outputs);
                    break :blk .{ .failed_drv = evaluated.items };
                }

                log.debug("built job {} as {s} producing {s}", .{ job, evaluated.items, outputs });

                break :blk .{ .ok = .{
                    .evaluated = evaluated.items,
                    .built_outputs = outputs,
                } };
            } else blk: {
                log.debug("evaluated job {}", .{job});

                break :blk .{ .ok = .{
                    .evaluated = evaluated.items,
                    .built_outputs = null,
                } };
            },
            .ifds => |ifds| blk: {
                // XXX build all IFDs in parallel
                var iter = ifds.iterator();
                while (iter.next()) |ifd| {
                    const outputs = try build(self.allocator, ifd.*, output_spec);
                    defer {
                        for (outputs) |output| self.allocator.free(output);
                        self.allocator.free(outputs);
                    }

                    log.debug("built job {} IFD {s} producing {s}", .{ job, ifd.*, outputs });

                    if (outputs.len == 0) {
                        log.debug("could not build job {} due to failure building IFD {s}", .{ job, ifd.* });
                        break :blk .{ .failed_drv = ifd.* };
                    }

                    continue;
                }
            },
        };

        defer switch (result) {
            .ok => |ok| if (ok.built_outputs) |outputs| {
                for (outputs) |output| self.allocator.free(output);
                self.allocator.free(outputs);
            },
            .failed_drv => {},
        };

        {
            var kv = blk: {
                self.jobs_mutex.lock();
                defer self.jobs_mutex.unlock();

                break :blk self.jobs.fetchRemove(job).?;
            };

            defer {
                // same as `job`
                kv.key.deinit(self.allocator);

                // same as `evaluation`, owns memory for `result`
                kv.value.deinit();
            }

            try self.runCallbacks(job, result);
        }

        break;
    }
}

const JobResult = union(enum) {
    ok: struct {
        evaluated: []const u8,
        built_outputs: ?[]const []const u8,
    },
    failed_drv: []const u8,
};

fn runCallbacks(self: *@This(), job: Job, result: JobResult) !void {
    const SelectCallback = sql.queries.nix_callback.SelectCallbackByAll(&.{ .id, .plugin, .function, .user_data });
    var callback_rows = blk: {
        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        break :blk try SelectCallback.rows(conn, .{ job.flake_url, job.expression, job.build });
    };
    errdefer callback_rows.deinit();

    var found_callback: bool = false;
    while (callback_rows.next()) |callback_row| {
        found_callback = true;

        var callback: components.CallbackUnmanaged = undefined;
        try sql.structFromRow(self.allocator, &callback, callback_row, SelectCallback.column, .{
            .func_name = .function,
            .user_data = .user_data,
        });
        defer callback.deinit(self.allocator);

        var runtime = try self.registry.runtime(SelectCallback.column(callback_row, .plugin));
        defer runtime.deinit();

        const linear = try runtime.linearMemoryAllocator();
        const linear_allocator = linear.allocator();

        var inputs = std.ArrayListUnmanaged(wasm.Value){};
        defer inputs.deinit(self.allocator);
        {
            try inputs.appendSlice(self.allocator, &.{
                .{ .i32 = @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, job.flake_url)).ptr)) },
                .{ .i32 = switch (result) {
                    .ok => |ok| @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, ok.evaluated)).ptr)),
                    .failed_drv => 0,
                } },
            });

            if (job.build) {
                const outputs, const outputs_len = switch (result) {
                    .ok => |ok| outputs: {
                        const addrs = try linear_allocator.alloc(wasm.usize, ok.built_outputs.?.len);
                        for (ok.built_outputs.?, addrs) |result_output, *addr| {
                            const out = try linear_allocator.dupeZ(u8, result_output);
                            addr.* = linear.memory.offset(out.ptr);
                        }
                        break :outputs .{ linear.memory.offset(addrs.ptr), addrs.len };
                    },
                    .failed_drv => .{ 0, 0 },
                };

                try inputs.appendSlice(self.allocator, &.{
                    .{ .i32 = @intCast(outputs) },
                    .{ .i32 = @intCast(outputs_len) },
                });
            }

            try inputs.append(self.allocator, .{ .i32 = switch (result) {
                .ok => 0,
                .failed_drv => |dep| @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, dep)).ptr)),
            } });
        }

        _ = try callback.run(self.allocator, runtime, inputs.items, &.{});

        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        try sql.queries.callback.deleteById.exec(conn, .{SelectCallback.column(callback_row, .id)});
    }

    if (!found_callback) log.err("no callbacks found for job {}", .{job});

    try callback_rows.deinitErr();
}

const Eval = union(enum) {
    ok: std.ArrayList(u8),
    ifds: std.BufSet,

    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            inline else => |*case| case.deinit(),
        }
    }
};

fn eval(self: @This(), flake_url: []const u8, apply: ?[]const u8, output: enum { raw, json }) !Eval {
    const ifds_tmp = try fs.tmpFile(self.allocator, .{ .read = true });
    defer ifds_tmp.deinit(self.allocator);

    {
        const args = try std.mem.concat(self.allocator, []const u8, &.{
            &.{
                "nix",
                "eval",
                "--restrict-eval",
                "--allow-import-from-derivation",
                "--build-hook",
                self.build_hook,
                "--max-jobs",
                "0",
                "--builders",
                ifds_tmp.path,
            },
            if (apply) |a| &.{ "--apply", a } else &.{},
            &.{
                switch (output) {
                    .raw => "--raw",
                    .json => "--json",
                },
                "--quiet",
                flake_url,
            },
        });
        defer self.allocator.free(args);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = args,
        });
        defer self.allocator.free(result.stderr);

        if (result.term == .Exited and result.term.Exited == 0) {
            return .{ .ok = std.ArrayList(u8).fromOwnedSlice(self.allocator, result.stdout) };
        } else {
            log.debug("command {s} terminated with {}\n{s}", .{ args, result.term, result.stderr });
            self.allocator.free(result.stdout);
        }
    }

    var ifds = std.BufSet.init(self.allocator);
    errdefer ifds.deinit();

    {
        const ifds_tmp_reader = ifds_tmp.file.reader();

        var ifd = std.ArrayListUnmanaged(u8){};
        defer ifd.deinit(self.allocator);

        const ifd_writer = ifd.writer(self.allocator);

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
fn build(allocator: std.mem.Allocator, store_drv: []const u8, output_spec: ?[]const u8) ![]const []const u8 {
    const installable = try std.mem.concat(allocator, u8, if (output_spec) |out| &.{ store_drv, "^", out } else &.{store_drv});
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
            "--quiet",
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
