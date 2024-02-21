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
wait_group: *std.Thread.WaitGroup,

build_hook: []const u8,

// could store this in the database but memory is easier for now
eval_jobs_mutex: std.Thread.Mutex = .{},
eval_jobs: std.HashMapUnmanaged(Job.Eval, EvalState, struct {
    pub fn hash(_: @This(), key: Job.Eval) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key, .Deep);
        return hasher.final();
    }

    pub fn eql(_: @This(), a: Job.Eval, b: Job.Eval) bool {
        return a.output_format == b.output_format and std.mem.eql(u8, a.expr, b.expr);
    }
}, std.hash_map.default_max_load_percentage) = .{},

jobs_thread_pool: std.Thread.Pool = undefined,

/// Only purpose is to reject new jobs during shutdown.
running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

mock_start_job: if (builtin.is_test) ?meta.Closure(
    fn (
        allocator: std.mem.Allocator,
        job: Job,
    ) (std.Thread.SpawnError || std.Thread.SetNameError || std.mem.Allocator.Error)!bool,
    true,
) else void = if (builtin.is_test) null,

pub const Job = union(enum) {
    build: Build,
    eval: Eval,

    pub const Build = struct {
        installable: []const u8,

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.installable);
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try std.fmt.format(writer, "`nix build {s}`", .{self.installable});
        }

        pub const Result = BuildResult;
    };

    pub const Eval = struct {
        expr: []const u8,
        // Naming this just `format` collides with custom `format()` for `std.fmt.format()`,
        // leading to a hard to understand error saying `type 'EvalFormat' is not a function`.
        output_format: EvalFormat,

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.expr);
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try std.fmt.format(writer, "`nix eval{s} --expr {s}`", .{
                switch (self.output_format) {
                    .nix => "",
                    .json => " --json",
                    .raw => " --raw",
                },
                self.expr,
            });
        }

        pub const Result = union(enum) {
            /// evaluation result
            ok: []const u8,
            /// evaluation error message
            failed: []const u8,
            /// IFD derivation that failed
            ifd_failed: []const u8,
            ifd_dep_failed: struct {
                /// IFD derivation
                ifd: []const u8,
                /// dependency derivation that failed
                drv: []const u8,
            },
        };
    };

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        switch (self) {
            inline else => |case| case.deinit(allocator),
        }
    }

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try switch (self) {
            inline else => |case| case.format(fmt, options, writer),
        };
    }
};

pub fn deinit(self: *@This()) void {
    self.allocator.free(self.build_hook);

    {
        var iter = self.eval_jobs.iterator();
        while (iter.next()) |entry| {
            entry.key_ptr.deinit(self.allocator);
            entry.value_ptr.deinit();
        }
        self.eval_jobs.deinit(self.allocator);
    }

    self.jobs_thread_pool.deinit();
}

pub const InitError = std.mem.Allocator.Error || std.Thread.SpawnError;

pub fn init(allocator: std.mem.Allocator, registry: *const Registry, wait_group: *std.Thread.WaitGroup) InitError!@This() {
    return .{
        .allocator = allocator,
        .registry = registry,
        .wait_group = wait_group,
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
        .nix_on_build = Runtime.HostFunctionDef{
            .signature = .{
                .params = &[_]wasm.Value.Type{.i32} ** 4,
                .returns = &.{},
            },
            .host_function = Runtime.HostFunction.init(onBuild, self),
        },
        .nix_on_eval = Runtime.HostFunctionDef{
            .signature = .{
                .params = &[_]wasm.Value.Type{.i32} ** 5,
                .returns = &.{},
            },
            .host_function = Runtime.HostFunction.init(onEval, self),
        },
    });
}

fn onBuild(self: *@This(), plugin_name: []const u8, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 4);
    std.debug.assert(outputs.len == 0);

    try components.rejectIfStopped(&self.running);

    const params = .{
        .func_name = wasm.span(memory, inputs[0]),
        .user_data_ptr = @as([*]const u8, @ptrCast(&memory[@intCast(inputs[1].i32)])),
        .user_data_len = @as(wasm.usize, @intCast(inputs[2].i32)),
        .installable = wasm.span(memory, inputs[3]),
    };

    const job = job: {
        const installable = try self.allocator.dupe(u8, params.installable);
        errdefer self.allocator.free(installable);

        break :job Job{ .build = .{ .installable = installable } };
    };
    errdefer job.deinit(self.allocator);

    try self.insertCallback(plugin_name, params.func_name, params.user_data_ptr, params.user_data_len, job);

    const started = try self.startJob(job);
    if (!started) job.deinit(self.allocator);
}

fn onEval(self: *@This(), plugin_name: []const u8, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 5);
    std.debug.assert(outputs.len == 0);

    try components.rejectIfStopped(&self.running);

    const params = .{
        .func_name = wasm.span(memory, inputs[0]),
        .user_data_ptr = @as([*]const u8, @ptrCast(&memory[@intCast(inputs[1].i32)])),
        .user_data_len = @as(wasm.usize, @intCast(inputs[2].i32)),
        .expr = wasm.span(memory, inputs[3]),
        .output_format = @as(EvalFormat, @enumFromInt(inputs[4].i32)),
    };

    const job = job: {
        const expr = try self.allocator.dupe(u8, params.expr);
        errdefer self.allocator.free(expr);

        break :job Job{ .eval = .{
            .expr = expr,
            .output_format = params.output_format,
        } };
    };
    errdefer job.deinit(self.allocator);

    try self.insertCallback(plugin_name, params.func_name, params.user_data_ptr, params.user_data_len, job);

    const started = try self.startJob(job);
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

    try sql.queries.Callback.insert.exec(conn, .{
        plugin_name,
        func_name,
        if (user_data_len != 0) .{ .value = user_data_ptr[0..user_data_len] } else null,
    });

    switch (job) {
        .build => |build_job| try sql.queries.NixBuildCallback.insert.exec(conn, .{ conn.lastInsertedRowId(), build_job.installable }),
        .eval => |eval_job| try sql.queries.NixEvalCallback.insert.exec(conn, .{ conn.lastInsertedRowId(), eval_job.expr, @intFromEnum(eval_job.output_format) }),
    }

    try conn.commit();
}

pub fn start(self: *@This()) (std.Thread.SpawnError || std.Thread.SetNameError || zqlite.Error)!void {
    try self.jobs_thread_pool.init(.{ .allocator = self.allocator });

    self.running.store(true, .Monotonic);

    {
        const SelectPending = sql.queries.NixBuildCallback.Select(&.{.installable});

        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        var rows = try SelectPending.rows(conn, .{});
        errdefer rows.deinit();
        while (rows.next()) |row| {
            const installable = try self.allocator.dupe(u8, SelectPending.column(row, .installable));
            errdefer self.allocator.free(installable);

            const job = Job{ .build = .{
                .installable = installable,
            } };

            const started = try self.startJob(job);
            if (!started) job.deinit(self.allocator);
        }
        try rows.deinitErr();
    }

    {
        const SelectPending = sql.queries.NixEvalCallback.Select(&.{ .expr, .format });

        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        var rows = try SelectPending.rows(conn, .{});
        errdefer rows.deinit();
        while (rows.next()) |row| {
            const expr = try self.allocator.dupe(u8, SelectPending.column(row, .expr));
            errdefer self.allocator.free(expr);

            const job = Job{ .eval = .{
                .expr = expr,
                .output_format = @enumFromInt(SelectPending.column(row, .format)),
            } };

            const started = try self.startJob(job);
            if (!started) job.deinit(self.allocator);
        }
        try rows.deinitErr();
    }
}

pub fn stop(self: *@This()) void {
    self.running.store(false, .Monotonic);
}

/// Returns whether a new job thread has been started.
/// If true, takes ownership of the `job` parameter, otherwise not.
fn startJob(self: *@This(), job: Job) (std.Thread.SpawnError || std.Thread.SetNameError || std.mem.Allocator.Error)!bool {
    if (comptime @TypeOf(self.mock_start_job) != void)
        if (self.mock_start_job) |mock| return mock.call(.{ self.allocator, job });

    if (switch (job) {
        .build => |build_job| running: {
            _ = build_job;

            // TODO check if this job is already running
            break :running false;
        },
        .eval => |eval_job| running: {
            self.eval_jobs_mutex.lock();
            defer self.eval_jobs_mutex.unlock();

            const gop = try self.eval_jobs.getOrPut(self.allocator, eval_job);
            if (gop.found_existing) break :running true;

            gop.value_ptr.* = .{ .ifds = std.BufSet.init(self.allocator) };

            break :running false;
        },
    }) {
        log.debug("job is already running: {}", .{job});
        return false;
    }

    log.debug("starting job {}", .{job});

    self.wait_group.start();
    errdefer self.wait_group.finish();

    try self.jobs_thread_pool.spawn(runJob, .{ self, job });

    return true;
}

fn runJob(self: *@This(), job: Job) void {
    defer {
        job.deinit(self.allocator);

        self.wait_group.finish();
    }

    (switch (job) {
        .build => |build_job| self.runBuildJob(build_job),
        .eval => |eval_job| self.runEvalJob(eval_job),
    }) catch |err| log.err("job {} failed: {s}", .{ job, @errorName(err) });
}

fn runBuildJob(self: *@This(), job: Job.Build) !void {
    const result = try build(self.allocator, job.installable);
    defer result.deinit(self.allocator);

    switch (result) {
        .outputs => |outputs| if (outputs.len == 0)
            log.debug("job {} failed", .{job})
        else
            log.debug("job {} produced outputs {s}", .{ job, outputs }),
        .dep_failed => |drv| log.debug("dependency {s} of job {} failed", .{ drv, job }),
    }

    try self.runBuildJobCallbacks(job, result);
}

fn runEvalJob(self: *@This(), job: Job.Eval) !void {
    // owns memory that `result` references so we can free it later
    var ifd_build_result: ?BuildResult = null;
    defer if (ifd_build_result) |build_result| build_result.deinit(self.allocator);

    const result: Job.Eval.Result = eval: {
        const max_eval_attempts = 10;
        var eval_attempts: usize = 0;
        while (eval_attempts < max_eval_attempts) : (eval_attempts += 1) {
            var eval_state = try self.eval(job.expr, job.output_format);

            {
                errdefer eval_state.deinit();

                self.eval_jobs_mutex.lock();
                defer self.eval_jobs_mutex.unlock();

                const job_state = self.eval_jobs.getPtr(job).?;
                job_state.deinit();
                job_state.* = eval_state;
            }

            switch (eval_state) {
                .ok => |evaluated| break :eval .{ .ok = evaluated.items },
                .failure => |msg| break :eval .{ .failed = msg.items },
                .ifds => |ifds| {
                    // XXX build all IFDs in parallel
                    var iter = ifds.iterator();
                    while (iter.next()) |ifd| {
                        const build_result = try build(self.allocator, ifd.*);
                        errdefer build_result.deinit(self.allocator);

                        switch (build_result) {
                            .outputs => |outputs| if (outputs.len == 0) {
                                log.debug("could not build IFD {s} for job {}", .{ ifd.*, job });
                                ifd_build_result = build_result;
                                break :eval .{ .ifd_failed = ifd.* };
                            } else {
                                log.debug("built IFD {s} producing {s} for job {}", .{ ifd.*, outputs, job });
                                build_result.deinit(self.allocator);
                            },
                            .dep_failed => |drv| {
                                log.debug("could not build dependency {s} of IFD {s} for job {}", .{ drv, ifd.*, job });
                                ifd_build_result = build_result;
                                break :eval .{ .ifd_dep_failed = .{ .drv = drv, .ifd = ifd.* } };
                            },
                        }
                    }
                },
            }
        } else {
            log.warn("max eval attempts exceeded for job {}", .{job});
            return error.MaxEvalAttemptsExceeded;
        }
    };

    var kv = blk: {
        self.eval_jobs_mutex.lock();
        defer self.eval_jobs_mutex.unlock();

        break :blk self.eval_jobs.fetchRemove(job).?;
    };

    // same as `eval_state`, owns memory referenced by `result`
    defer kv.value.deinit();

    try self.runEvalJobCallbacks(job, result);
}

fn runBuildJobCallbacks(self: *@This(), job: Job.Build, result: Job.Build.Result) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    var callback_rows = std.ArrayListUnmanaged(struct {
        id: i64,
        plugin: []const u8,
        function: [:0]const u8,
        user_data: ?[]const u8,
    }){};
    defer callback_rows.deinit(self.allocator);

    {
        const SelectCallback = sql.queries.NixBuildCallback.SelectCallbackByInstallable(&.{ .id, .plugin, .function, .user_data });

        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        var rows = try SelectCallback.rows(conn, .{job.installable});
        errdefer rows.deinit();

        const arena_allocator = arena.allocator();

        while (rows.next()) |row| try sql.structFromRow(arena_allocator, try callback_rows.addOne(self.allocator), row, SelectCallback.column, .{
            .id = .id,
            .plugin = .plugin,
            .function = .function,
            .user_data = .user_data,
        });

        if (callback_rows.items.len == 0) log.err("no callbacks found for job {}", .{job});

        try rows.deinitErr();
    }

    for (callback_rows.items) |callback_row| {
        const callback = components.CallbackUnmanaged{
            .func_name = callback_row.function,
            .user_data = callback_row.user_data,
        };

        var runtime = try self.registry.runtime(callback_row.plugin);
        defer runtime.deinit();

        const linear = try runtime.linearMemoryAllocator();
        const linear_allocator = linear.allocator();

        _ = try callback.run(self.allocator, runtime, &.{
            .{ .i32 = switch (result) {
                .outputs => |outputs| if (outputs.len == 0) 0 else addrs: {
                    const addrs = try linear_allocator.alloc(wasm.usize, outputs.len);
                    for (outputs, addrs) |output, *addr| {
                        const out = try linear_allocator.dupeZ(u8, output);
                        addr.* = linear.memory.offset(out.ptr);
                    }
                    break :addrs @intCast(linear.memory.offset(addrs.ptr));
                },
                .dep_failed => 0,
            } },
            .{ .i32 = switch (result) {
                .outputs => |outputs| @intCast(outputs.len),
                .dep_failed => 0,
            } },
            .{ .i32 = switch (result) {
                .outputs => 0,
                .dep_failed => |drv| @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, drv)).ptr)),
            } },
        }, &.{});

        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        try sql.queries.Callback.deleteById.exec(conn, .{callback_row.id});
    }
}

fn runEvalJobCallbacks(self: *@This(), job: Job.Eval, result: Job.Eval.Result) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    var callback_rows = std.ArrayListUnmanaged(struct {
        id: i64,
        plugin: []const u8,
        function: [:0]const u8,
        user_data: ?[]const u8,
    }){};
    defer callback_rows.deinit(self.allocator);

    {
        const SelectCallback = sql.queries.NixEvalCallback.SelectCallbackByExprAndFormat(&.{ .id, .plugin, .function, .user_data });

        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        var rows = try SelectCallback.rows(conn, .{ job.expr, @intFromEnum(job.output_format) });
        errdefer rows.deinit();

        const arena_allocator = arena.allocator();

        while (rows.next()) |row| try sql.structFromRow(arena_allocator, try callback_rows.addOne(self.allocator), row, SelectCallback.column, .{
            .id = .id,
            .plugin = .plugin,
            .function = .function,
            .user_data = .user_data,
        });

        if (callback_rows.items.len == 0) log.err("no callbacks found for job {}", .{job});

        try rows.deinitErr();
    }

    for (callback_rows.items) |callback_row| {
        const callback = components.CallbackUnmanaged{
            .func_name = callback_row.function,
            .user_data = callback_row.user_data,
        };

        var runtime = try self.registry.runtime(callback_row.plugin);
        defer runtime.deinit();

        const linear = try runtime.linearMemoryAllocator();
        const linear_allocator = linear.allocator();

        _ = try callback.run(self.allocator, runtime, &.{
            .{ .i32 = switch (result) {
                .ok => |evaluated| @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, evaluated)).ptr)),
                else => 0,
            } },
            .{ .i32 = switch (result) {
                .failed => |msg| @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, msg)).ptr)),
                else => 0,
            } },
            .{ .i32 = switch (result) {
                .ifd_failed => |drv| @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, drv)).ptr)),
                .ifd_dep_failed => |ifd_dep_failed| @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, ifd_dep_failed.ifd)).ptr)),
                else => 0,
            } },
            .{ .i32 = switch (result) {
                .ifd_dep_failed => |ifd_dep_failed| @intCast(linear.memory.offset((try linear_allocator.dupeZ(u8, ifd_dep_failed.drv)).ptr)),
                else => 0,
            } },
        }, &.{});

        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        try sql.queries.Callback.deleteById.exec(conn, .{callback_row.id});
    }
}

pub const EvalFormat = enum { nix, json, raw };

pub const EvalState = union(enum) {
    ok: std.ArrayList(u8),
    ifds: std.BufSet,
    /// error message
    failure: std.ArrayList(u8),

    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            inline else => |*case| case.deinit(),
        }
    }
};

fn eval(self: @This(), expression: []const u8, format: EvalFormat) !EvalState {
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
            switch (format) {
                .nix => &.{},
                .json => &.{"--json"},
                .raw => &.{"--raw"},
            },
            &.{
                "--quiet",
                "--expr",
                expression,
            },
        });
        defer self.allocator.free(args);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = args,
        });
        defer self.allocator.free(result.stderr);

        if (result.term == .Exited and result.term.Exited == 0) {
            defer self.allocator.free(result.stderr);
            return .{ .ok = std.ArrayList(u8).fromOwnedSlice(self.allocator, result.stdout) };
        } else log.debug("command {s} terminated with {}", .{ args, result.term });

        // TODO catch eval failure
        // return .{ .failed = std.ArrayList(u8).fromOwnedSlice(self.allocator, result.stderr) };
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

pub const BuildResult = union(enum) {
    /// Output paths produced.
    /// If empty, the build failed.
    outputs: []const []const u8,
    /// dependency derivation that failed
    dep_failed: []const u8,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        switch (self) {
            .outputs => |outputs| {
                for (outputs) |output| allocator.free(output);
                allocator.free(outputs);
            },
            .dep_failed => |drv| allocator.free(drv),
        }
    }
};

fn build(allocator: std.mem.Allocator, installable: []const u8) !BuildResult {
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

    var outputs = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (outputs.items) |output| allocator.free(output);
        outputs.deinit(allocator);
    }

    if (result.term == .Exited and result.term.Exited == 0) {
        var iter = std.mem.tokenizeScalar(u8, result.stdout, '\n');
        while (iter.next()) |output|
            try outputs.append(allocator, try allocator.dupe(u8, output));
    } else log.debug("build of {s} failed: {s}", .{ installable, result.stderr });

    // TODO discover BuildResult.dep_failed

    return .{ .outputs = try outputs.toOwnedSlice(allocator) };
}

test {
    _ = @import("nix/build-hook/main.zig");
}
