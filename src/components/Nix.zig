const builtin = @import("builtin");
const std = @import("std");
const zqlite = @import("zqlite");

const lib = @import("lib");
const fmt = lib.fmt;
const meta = lib.meta;
const nix = lib.nix;
const wasm = lib.wasm;

const c = @import("../c.zig");
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
allowed_uris: []const []const u8,

build_jobs_mutex: std.Thread.Mutex = .{},
build_jobs: std.HashMapUnmanaged([]const []const u8, void, struct {
    pub fn hash(_: @This(), key: []const []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key, .Deep);
        return hasher.final();
    }

    pub fn eql(_: @This(), a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y|
            if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }
}, std.hash_map.default_max_load_percentage) = .{},

eval_jobs_mutex: std.Thread.Mutex = .{},
eval_jobs: std.HashMapUnmanaged(Job.Eval, EvalState, struct {
    pub fn hash(_: @This(), key: Job.Eval) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key, .Deep);
        return hasher.final();
    }

    pub fn eql(_: @This(), a: Job.Eval, b: Job.Eval) bool {
        return a.output_format == b.output_format and
            (if (a.flake != null and b.flake != null) std.mem.eql(u8, a.flake.?, b.flake.?) else a.flake == null and b.flake == null) and
            std.mem.eql(u8, a.expr, b.expr);
    }
}, std.hash_map.default_max_load_percentage) = .{},

// If this is not null, it has been initialized so we need to deinit it.
// Wrapped in an optional so that we know whether we need to deinit,
// as calling `deinit()` without previously calling `init()` will result in a crash.
// We cannot call `jobs_thread_pool.init()` in `@This().init()`
// because `std.Thread.Pool` cannot be copied to return it.
jobs_thread_pool: ?std.Thread.Pool = null,

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
        installables: []const []const u8,

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            for (self.installables) |installable| allocator.free(installable);
            allocator.free(self.installables);
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll("`nix build ");
            for (self.installables, 1..) |installable, i| {
                try writer.writeAll(installable);
                if (i != self.installables.len) try writer.writeByte(' ');
            }
            try writer.writeAll("`");
        }

        pub const Result = BuildResult;
    };

    pub const Eval = struct {
        flake: ?[]const u8,
        expr: []const u8,
        // Naming this just `format` collides with custom `format()` for `std.fmt.format()`,
        // leading to a hard to understand error saying `type 'EvalFormat' is not a function`.
        output_format: EvalFormat,

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            if (self.flake) |f| allocator.free(f);
            allocator.free(self.expr);
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll("`nix eval");
            try writer.writeAll(switch (self.output_format) {
                .nix => "",
                .json => " --json",
                .raw => " --raw",
            });

            try writer.writeAll(if (self.flake != null) " --apply " else " --expr ");
            try writer.print("{s}", .{fmt.oneline(self.expr)});

            if (self.flake) |f| {
                try writer.writeByte(' ');
                try writer.writeAll(f);
                try writer.writeAll("#.");
            }

            try writer.writeByte('`');
        }

        pub const Result = union(enum) {
            /// evaluation result
            ok: []const u8,
            /// evaluation error message
            failed: []const u8,
            ifd_failed: struct {
                /// IFD derivations that failed
                ifds: []const []const u8,
                /// dependency derivations that failed
                deps: []const []const u8,
            },
            /// max eval attempts exceeded
            ifd_too_deep,
        };
    };

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        switch (self) {
            inline else => |case| case.deinit(allocator),
        }
    }

    pub fn format(self: @This(), comptime fmt_: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try switch (self) {
            inline else => |case| case.format(fmt_, options, writer),
        };
    }
};

pub fn deinit(self: *@This()) void {
    self.allocator.free(self.build_hook);

    for (self.allowed_uris) |allowed_uri| self.allocator.free(allowed_uri);
    self.allocator.free(self.allowed_uris);

    std.debug.assert(self.eval_jobs.size == 0);
    self.eval_jobs.deinit(self.allocator);

    std.debug.assert(self.build_jobs.size == 0);
    self.build_jobs.deinit(self.allocator);

    if (self.jobs_thread_pool) |*pool| {
        pool.deinit();
        self.jobs_thread_pool = null;
    }
}

pub const InitError = error{
    Overflow,
    InvalidVersion,
    UnknownNixVersion,
    IncompatibleNixVersion,
    CouldNotReadNixConfig,
} ||
    std.mem.Allocator.Error ||
    std.Thread.SpawnError ||
    std.process.Child.RunError ||
    std.json.ParseError(std.json.Scanner);

pub fn init(allocator: std.mem.Allocator, registry: *const Registry, wait_group: *std.Thread.WaitGroup) InitError!@This() {
    if (!builtin.is_test) {
        // we need #. flake syntax
        const min_nix_version = std.SemanticVersion{ .major = 2, .minor = 19, .patch = 0 };

        const version = try nix.version(allocator);

        if (version.order(min_nix_version) == .lt) {
            log.err("nix version {} is too old, must be {} or newer", .{ version, min_nix_version });
            return error.IncompatibleNixVersion;
        }
    }

    const build_hook = build_hook: {
        const exe_path = try c.whereami.getExecutablePath(allocator);
        defer exe_path.deinit(allocator);

        break :build_hook try std.fs.path.join(allocator, &.{
            std.fs.path.dirname(exe_path.path).?,
            "..",
            "libexec",
            "cizero",
            "components",
            name,
            "build-hook",
        });
    };
    errdefer allocator.free(build_hook);

    const allowed_uris = if (builtin.is_test) try allocator.alloc([]const u8, 0) else allowed_uris: {
        const nix_config = nix_config: {
            var diagnostics: ?nix.ChildProcessDiagnostics = null;
            defer if (diagnostics) |d| d.deinit(allocator);
            break :nix_config nix.config(allocator, &diagnostics) catch |err| return switch (err) {
                error.CouldNotReadNixConfig => blk: {
                    log.err("could not read nix config: {}, stderr: {s}", .{ diagnostics.?.term, diagnostics.?.stderr });
                    break :blk err;
                },
                else => err,
            };
        };
        defer nix_config.deinit();

        var allowed_uris = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, nix_config.value.@"allowed-uris".value.len);
        errdefer {
            for (allowed_uris.items) |allowed_uri| allocator.free(allowed_uri);
            allowed_uris.deinit(allocator);
        }

        for (nix_config.value.@"allowed-uris".value) |allowed_uri|
            allowed_uris.appendAssumeCapacity(try allocator.dupe(u8, allowed_uri));

        log.debug("allowed URIs: {s}", .{allowed_uris.items});

        break :allowed_uris try allowed_uris.toOwnedSlice(allocator);
    };
    errdefer {
        for (allowed_uris) |allowed_uri| allocator.free(allowed_uri);
        allocator.free(allowed_uris);
    }

    return .{
        .allocator = allocator,
        .registry = registry,
        .wait_group = wait_group,
        .build_hook = build_hook,
        .allowed_uris = allowed_uris,
    };
}

pub fn hostFunctions(self: *@This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef) {
    return meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef), allocator, .{
        .nix_on_build = Runtime.HostFunctionDef{
            .signature = .{
                .params = &[_]wasm.Value.Type{.i32} ** 5,
                .returns = &.{},
            },
            .host_function = Runtime.HostFunction.init(onBuild, self),
        },
        .nix_on_eval = Runtime.HostFunctionDef{
            .signature = .{
                .params = &[_]wasm.Value.Type{.i32} ** 6,
                .returns = &.{},
            },
            .host_function = Runtime.HostFunction.init(onEval, self),
        },
        .nix_build_state = Runtime.HostFunctionDef{
            .signature = .{
                .params = &[_]wasm.Value.Type{.i32} ** 1,
                .returns = &.{.i32},
            },
            .host_function = Runtime.HostFunction.init(buildState, self),
        },
        .nix_eval_state = Runtime.HostFunctionDef{
            .signature = .{
                .params = &[_]wasm.Value.Type{.i32} ** 3,
                .returns = &.{.i32},
            },
            .host_function = Runtime.HostFunction.init(evalState, self),
        },
    });
}

fn buildState(self: *@This(), _: []const u8, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 1);
    std.debug.assert(outputs.len == 1);

    const params = .{
        .installable_addrs_ptr = @as([*]const wasm.usize, @alignCast(@ptrCast(&memory[@intCast(inputs[0].i32)]))),
        .installable_addrs_len = @as(wasm.usize, @intCast(inputs[1].i32)),
    };

    const installables = try self.allocator.alloc([]const u8, params.installable_addrs_len);
    defer self.allocator.free(installables);

    for (installables, params.installable_addrs_ptr[0..params.installable_addrs_len]) |*installable, installable_addr|
        installable.* = wasm.span(memory, installable_addr);

    const building = building: {
        self.build_jobs_mutex.lock();
        defer self.build_jobs_mutex.unlock();

        break :building self.build_jobs.contains(installables);
    };

    outputs[0] = .{ .i32 = @intFromBool(building) };
}

fn evalState(self: *@This(), _: []const u8, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 3);
    std.debug.assert(outputs.len == 1);

    const params = .{
        .flake = if (inputs[0].i32 != 0) wasm.span(memory, inputs[0]) else null,
        .expr = wasm.span(memory, inputs[1]),
        .output_format = @as(EvalFormat, @enumFromInt(inputs[2].i32)),
    };

    const state = state: {
        self.eval_jobs_mutex.lock();
        defer self.eval_jobs_mutex.unlock();

        const state = self.eval_jobs.getPtr(.{
            .flake = params.flake,
            .expr = params.expr,
            .output_format = params.output_format,
        });

        break :state if (state) |s| std.meta.activeTag(s.*) else null;
    };

    outputs[0] = .{ .i32 = if (state) |s| @intFromEnum(s) + 1 else 0 };
}

fn onBuild(self: *@This(), plugin_name: []const u8, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 5);
    std.debug.assert(outputs.len == 0);

    try components.rejectIfStopped(&self.running);

    const params = .{
        .func_name = wasm.span(memory, inputs[0]),
        .user_data_ptr = @as([*]const u8, @ptrCast(&memory[@intCast(inputs[1].i32)])),
        .user_data_len = @as(wasm.usize, @intCast(inputs[2].i32)),
        .installable_addrs_ptr = @as([*]const wasm.usize, @alignCast(@ptrCast(&memory[@intCast(inputs[3].i32)]))),
        .installable_addrs_len = @as(wasm.usize, @intCast(inputs[4].i32)),
    };

    var installables = try std.ArrayListUnmanaged([]const u8).initCapacity(self.allocator, params.installable_addrs_len);
    errdefer {
        for (installables.items) |installable| self.allocator.free(installable);
        installables.deinit(self.allocator);
    }

    for (params.installable_addrs_ptr[0..params.installable_addrs_len]) |installable_addr| {
        const installable = try self.allocator.dupe(u8, wasm.span(memory, installable_addr));
        errdefer self.allocator.free(installable);

        try installables.append(self.allocator, installable);
    }

    const job = Job{ .build = .{ .installables = try installables.toOwnedSlice(self.allocator) } };
    errdefer job.deinit(self.allocator);

    try self.insertCallback(plugin_name, params.func_name, params.user_data_ptr, params.user_data_len, job);

    const started = try self.startJob(job);
    if (!started) job.deinit(self.allocator);
}

fn onEval(self: *@This(), plugin_name: []const u8, memory: []u8, _: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) !void {
    std.debug.assert(inputs.len == 6);
    std.debug.assert(outputs.len == 0);

    try components.rejectIfStopped(&self.running);

    const params = .{
        .func_name = wasm.span(memory, inputs[0]),
        .user_data_ptr = @as([*]const u8, @ptrCast(&memory[@intCast(inputs[1].i32)])),
        .user_data_len = @as(wasm.usize, @intCast(inputs[2].i32)),
        .flake = if (inputs[3].i32 != 0) wasm.span(memory, inputs[3]) else null,
        .expr = wasm.span(memory, inputs[4]),
        .output_format = @as(EvalFormat, @enumFromInt(inputs[5].i32)),
    };

    const job = job: {
        const expr = try self.allocator.dupe(u8, params.expr);
        errdefer self.allocator.free(expr);

        const flake = if (params.flake) |f| try self.allocator.dupe(u8, f) else null;
        errdefer if (flake) |f| self.allocator.free(f);

        break :job Job{ .eval = .{
            .flake = flake,
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
        .build => |build_job| {
            const installables = try sql.queries.NixBuildCallback.encodeInstallables(self.allocator, build_job.installables);
            defer self.allocator.free(installables);

            try sql.queries.NixBuildCallback.insert.exec(conn, .{ conn.lastInsertedRowId(), installables });
        },
        .eval => |eval_job| try sql.queries.NixEvalCallback.insert.exec(conn, .{ conn.lastInsertedRowId(), eval_job.flake, eval_job.expr, @intFromEnum(eval_job.output_format) }),
    }

    try conn.commit();
}

pub fn start(self: *@This()) (std.Thread.SpawnError || std.Thread.SetNameError || zqlite.Error)!void {
    {
        std.debug.assert(self.jobs_thread_pool == null);
        self.jobs_thread_pool = undefined;
        errdefer self.jobs_thread_pool = null;
        try self.jobs_thread_pool.?.init(.{ .allocator = self.allocator });
    }

    self.running.store(true, .monotonic);

    {
        const rows = rows: {
            const conn = self.registry.db_pool.acquire();
            defer self.registry.db_pool.release(conn);

            break :rows try sql.queries.NixBuildCallback.Select(&.{.installables})
                .query(self.allocator, conn, .{});
        };
        defer self.allocator.free(rows);

        for (rows) |row| {
            const installables = try sql.queries.NixBuildCallback.decodeInstallables(self.allocator, row.installables);
            errdefer self.allocator.free(installables);

            const job = Job{ .build = .{ .installables = installables } };

            const started = try self.startJob(job);
            if (!started) job.deinit(self.allocator);
        }
    }

    {
        const rows = rows: {
            const conn = self.registry.db_pool.acquire();
            defer self.registry.db_pool.release(conn);

            break :rows try sql.queries.NixEvalCallback.Select(&.{ .flake, .expr, .format })
                .query(self.allocator, conn, .{});
        };
        defer self.allocator.free(rows);

        for (rows) |row| {
            const job = Job{ .eval = .{
                .flake = row.flake,
                .expr = row.expr,
                .output_format = @enumFromInt(row.format),
            } };

            const started = try self.startJob(job);
            if (!started) job.deinit(self.allocator);
        }
    }
}

pub fn stop(self: *@This()) void {
    self.running.store(false, .monotonic);
}

/// Returns whether a new job thread has been started.
/// If true, takes ownership of the `job` parameter, otherwise not.
fn startJob(self: *@This(), job: Job) (std.Thread.SpawnError || std.Thread.SetNameError || std.mem.Allocator.Error)!bool {
    if (comptime @TypeOf(self.mock_start_job) != void)
        if (self.mock_start_job) |mock| return mock.call(.{ self.allocator, job });

    if (switch (job) {
        .build => |build_job| running: {
            self.build_jobs_mutex.lock();
            defer self.build_jobs_mutex.unlock();

            break :running try self.build_jobs.fetchPut(self.allocator, build_job.installables, {}) != null;
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

    try self.jobs_thread_pool.?.spawn(runJob, .{ self, job });

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
    const result = result: {
        errdefer self.removeBuildJob(job);

        const result = try build(self.allocator, job.installables);
        errdefer result.deinit(self.allocator);

        switch (result) {
            .outputs => |outputs| log.debug("job {} produced outputs {s}", .{ job, outputs }),
            .failed => |failed| log.debug("builds {s} and dependents {s} of job {} failed", .{ failed.builds, failed.dependents, job }),
        }

        break :result result;
    };
    defer result.deinit(self.allocator);

    self.removeBuildJob(job);

    self.runBuildJobCallbacks(job, result) catch |err| {
        log.err("failed to run callbacks for job {}: {s}", .{ job, @errorName(err) });
        return err;
    };
}

fn removeBuildJob(self: *@This(), job: Job.Build) void {
    self.build_jobs_mutex.lock();
    defer self.build_jobs_mutex.unlock();

    std.debug.assert(self.build_jobs.fetchRemove(job.installables) != null);
}

fn runEvalJob(self: *@This(), job: Job.Eval) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const result: Job.Eval.Result = eval: {
        errdefer {
            var eval_state = self.removeEvalJob(job);
            eval_state.deinit();
        }

        const max_eval_attempts = 100;
        var eval_attempts: usize = 0;
        while (eval_attempts < max_eval_attempts) : (eval_attempts += 1) {
            var eval_state = self.eval(job.flake, job.expr, job.output_format) catch |err| {
                log.err("failed to evaluate job {}: {s}", .{ job, @errorName(err) });
                return err;
            };
            errdefer eval_state.deinit();

            {
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
                    // This is `ifds` as a list, only really needed for logging.
                    var ifds_all = try std.ArrayListUnmanaged([]const u8).initCapacity(self.allocator, ifds.count());
                    defer ifds_all.deinit(self.allocator);

                    var ifds_failed = std.ArrayListUnmanaged([]const u8){};
                    errdefer ifds_failed.deinit(arena_allocator);

                    var ifd_deps_failed = std.ArrayListUnmanaged([]const u8){};
                    errdefer ifd_deps_failed.deinit(arena_allocator);

                    const build_result = build_result: {
                        var installables = try std.ArrayListUnmanaged([]const u8).initCapacity(self.allocator, ifds.count());
                        defer {
                            for (installables.items) |installable| self.allocator.free(installable);
                            installables.deinit(self.allocator);
                        }

                        var iter = ifds.iterator();
                        while (iter.next()) |ifd| {
                            if (std.debug.runtime_safety) std.debug.assert(std.mem.endsWith(u8, ifd.*, ".drv"));

                            try ifds_all.append(self.allocator, ifd.*);

                            // XXX improve `build-hook` to return the needed outputs so that we don't have to build them all here
                            const installable = try std.mem.concat(self.allocator, u8, &.{ ifd.*, "^*" });
                            errdefer self.allocator.free(installable);

                            try installables.append(self.allocator, installable);
                        }

                        break :build_result build(arena_allocator, installables.items) catch |err| {
                            log.err("failed to build IFDs {s} for job {}: {s}", .{ ifds_all.items, job, @errorName(err) });
                            return err;
                        };
                    };
                    errdefer build_result.deinit(arena_allocator);

                    switch (build_result) {
                        .outputs => |outputs| {
                            defer build_result.deinit(arena_allocator);
                            log.debug("built IFDs {s} producing {s} for job {}", .{ ifds_all.items, outputs, job });
                        },
                        .failed => |failed| {
                            inline for (.{ failed.builds, failed.dependents }) |drvs|
                                for (drvs) |drv|
                                    for (ifds_all.items) |ifd| {
                                        if (std.mem.eql(u8, ifd, drv)) {
                                            try ifds_failed.append(arena_allocator, ifd);
                                            break;
                                        }
                                    } else try ifd_deps_failed.append(arena_allocator, drv);

                            log.debug("could not build IFDs for job {}\nIFDs: {s}\nIFD dependencies: {s}", .{
                                job,
                                ifds_failed.items,
                                ifd_deps_failed.items,
                            });
                            break :eval .{ .ifd_failed = .{
                                .ifds = try ifds_failed.toOwnedSlice(arena_allocator),
                                .deps = try ifd_deps_failed.toOwnedSlice(arena_allocator),
                            } };
                        },
                    }

                    ifds_failed.deinit(arena_allocator);
                    ifd_deps_failed.deinit(arena_allocator);
                },
            }
        } else {
            log.warn("max eval attempts exceeded for job {}", .{job});
            break :eval .ifd_too_deep;
        }
    };

    var eval_state = self.removeEvalJob(job);

    // same as last `eval_state` from loop above, owns memory referenced by `result`
    defer eval_state.deinit();

    self.runEvalJobCallbacks(job, result) catch |err| {
        log.err("failed to run callbacks for job {}: {s}", .{ job, @errorName(err) });
        return err;
    };
}

fn removeEvalJob(self: *@This(), job: Job.Eval) EvalState {
    self.eval_jobs_mutex.lock();
    defer self.eval_jobs_mutex.unlock();

    return self.eval_jobs.fetchRemove(job).?.value;
}

fn runBuildJobCallbacks(self: *@This(), job: Job.Build, result: Job.Build.Result) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    const callback_rows = rows: {
        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        const installables = try sql.queries.NixBuildCallback.encodeInstallables(self.allocator, job.installables);
        defer self.allocator.free(installables);

        break :rows try sql.queries.NixBuildCallback.SelectCallbackByInstallables(&.{ .id, .plugin, .function, .user_data })
            .query(arena_allocator, conn, .{installables});
    };
    if (callback_rows.len == 0) log.err("no callbacks found for job {}", .{job});

    for (callback_rows) |callback_row| {
        const callback = components.CallbackUnmanaged{
            .func_name = try arena_allocator.dupeZ(u8, callback_row.function),
            .user_data = if (callback_row.user_data) |ud| ud.value else null,
        };

        var runtime = try self.registry.runtime(callback_row.plugin);
        defer runtime.deinit();

        const linear = try runtime.linearMemoryAllocator();

        _ = try callback.run(self.allocator, runtime, &.{
            .{ .i32 = switch (result) {
                .outputs => |outputs| @intCast(try linear.dupeStringSliceAddr(outputs)),
                .failed => 0,
            } },
            .{ .i32 = switch (result) {
                .outputs => |outputs| @intCast(outputs.len),
                .failed => 0,
            } },
            .{ .i32 = switch (result) {
                .outputs => 0,
                .failed => |failed| @intCast(try linear.dupeStringSliceAddr(failed.builds)),
            } },
            .{ .i32 = switch (result) {
                .outputs => 0,
                .failed => |failed| @intCast(failed.builds.len),
            } },
            .{ .i32 = switch (result) {
                .outputs => 0,
                .failed => |failed| @intCast(try linear.dupeStringSliceAddr(failed.dependents)),
            } },
            .{ .i32 = switch (result) {
                .outputs => 0,
                .failed => |failed| @intCast(failed.dependents.len),
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

    const arena_allocator = arena.allocator();

    const callback_rows = rows: {
        const conn = self.registry.db_pool.acquire();
        defer self.registry.db_pool.release(conn);

        break :rows try sql.queries.NixEvalCallback.SelectCallbackByFlakeAndExprAndFormat(&.{ .id, .plugin, .function, .user_data })
            .query(arena_allocator, conn, .{ job.flake, job.expr, @intFromEnum(job.output_format) });
    };
    if (callback_rows.len == 0) log.err("no callbacks found for job {}", .{job});

    for (callback_rows) |callback_row| {
        const callback = components.CallbackUnmanaged{
            .func_name = try arena_allocator.dupeZ(u8, callback_row.function),
            .user_data = if (callback_row.user_data) |ud| ud.value else null,
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
                .ifd_failed => |ifd_failed| @intCast(try linear.dupeStringSliceAddr(ifd_failed.ifds)),
                else => 0,
            } },
            .{ .i32 = switch (result) {
                .ifd_failed => |ifd_failed| @intCast(ifd_failed.ifds.len),
                else => 0,
            } },
            .{ .i32 = switch (result) {
                .ifd_failed => |ifd_failed| @intCast(try linear.dupeStringSliceAddr(ifd_failed.deps)),
                else => 0,
            } },
            .{ .i32 = switch (result) {
                .ifd_failed => |ifd_failed| @intCast(ifd_failed.deps.len),
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

fn eval(self: @This(), flake: ?[]const u8, expression: []const u8, format: EvalFormat) !EvalState {
    if (flake) |f| {
        inline for (.{ "/", ".", "path:", "file:" }) |prefix|
            if (std.mem.startsWith(u8, f, prefix))
                for (self.allowed_uris) |allowed_uri| {
                    // XXX precisly check by the actual rules, see `nix show-config --json | jq '."allowed-uris".description'`
                    if (std.mem.startsWith(u8, f, allowed_uri)) {
                        log.debug("flake URL {s} allowed because of allowed URI {s}", .{ f, allowed_uri });
                        break;
                    }
                } else {
                    log.debug("flake URL {s} denied", .{f});
                    return .{
                        .failure = std.ArrayList(u8).fromOwnedSlice(
                            self.allocator,
                            try self.allocator.dupe(u8, "flake URL with prefix \"" ++ prefix ++ "\" must be in allowed-uris to be allowed"),
                        ),
                    };
                };

        if (std.mem.indexOfScalar(u8, f, '#') != null) return .{
            .failure = std.ArrayList(u8).fromOwnedSlice(
                self.allocator,
                try self.allocator.dupe(u8, "flake URL must not have an attribute path"),
            ),
        };
    }

    const ifds_tmp = try fs.tmpFile(self.allocator, .{ .read = true });
    defer ifds_tmp.deinit(self.allocator);

    const flake_ref = if (flake) |f| try std.mem.concat(self.allocator, u8, &.{ f, "#." }) else null;
    defer if (flake_ref) |ref| self.allocator.free(ref);

    const allowed_uris = if (flake) |f|
        if (locks: {
            var diagnostics: ?nix.ChildProcessDiagnostics = null;
            errdefer if (diagnostics) |d| d.deinit(self.allocator);
            break :locks nix.flakeMetadataLocks(self.allocator, f, .{}, &diagnostics) catch |err| return switch (err) {
                error.FlakePrefetchFailed => .{ .failure = std.ArrayList(u8).fromOwnedSlice(self.allocator, diagnostics.?.stderr) },
                else => err,
            };
        }) |locks| allowed_uris: {
            defer locks.deinit();

            var allowed_uris = std.ArrayListUnmanaged(u8){};
            errdefer allowed_uris.deinit(self.allocator);

            const allowed_uris_writer = allowed_uris.writer(self.allocator);

            for (locks.value.nodes.map.values()) |node| switch (node) {
                .root => {},
                inline else => |n| {
                    try n.locked.writeAllowedUri(self.allocator, allowed_uris_writer);
                    try allowed_uris_writer.writeByte(' ');
                },
            };

            break :allowed_uris try allowed_uris.toOwnedSlice(self.allocator);
        } else null
    else
        null;
    defer if (allowed_uris) |uris| self.allocator.free(uris);

    const args = try std.mem.concat(self.allocator, []const u8, &.{
        &.{
            "nix",
            "eval",
            "--quiet",
            "--restrict-eval",
            "--allow-import-from-derivation",
            "--no-write-lock-file",
            "--build-hook",
            self.build_hook,
            "--max-jobs",
            "0",
            "--builders",
            ifds_tmp.path,
        },
        if (allowed_uris) |uris| &.{
            "--extra-allowed-uris",
            uris,
        } else &.{},
        switch (format) {
            .nix => &.{},
            .json => &.{"--json"},
            .raw => &.{"--raw"},
        },
        if (flake_ref) |ref| &.{
            "--apply",
            expression,
            ref,
        } else &.{
            "--expr",
            expression,
        },
    });
    defer self.allocator.free(args);

    const result = try std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = args,
        .max_output_bytes = 1024 * 1024 * 8,
    });
    errdefer {
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
    }

    var ifds = std.BufSet.init(self.allocator);
    errdefer ifds.deinit();

    {
        const ifds_tmp_reader = ifds_tmp.file.reader();

        var ifd = std.ArrayListUnmanaged(u8){};
        defer ifd.deinit(self.allocator);

        const ifd_writer = ifd.writer(self.allocator);

        while (ifds_tmp_reader.streamUntilDelimiter(ifd_writer, '\n', null)) {
            try ifds.insert(ifd.items);
            ifd.clearRetainingCapacity();
        } else |err| if (err != error.EndOfStream) return err;
    }

    if (comptime std.log.logEnabled(.debug, log_scope)) {
        var iter = ifds.iterator();
        while (iter.next()) |ifd| log.debug("found IFD: {s}", .{ifd.*});
    }

    if (ifds.count() != 0) {
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
        return .{ .ifds = ifds };
    } else ifds.deinit();

    if (result.term == .Exited and result.term.Exited == 0) {
        self.allocator.free(result.stderr);
        return .{ .ok = std.ArrayList(u8).fromOwnedSlice(self.allocator, result.stdout) };
    } else log.debug("command {s} terminated with {}", .{ args, result.term });

    self.allocator.free(result.stdout);
    return .{ .failure = std.ArrayList(u8).fromOwnedSlice(self.allocator, result.stderr) };
}

pub const BuildResult = union(enum) {
    /// output paths produced
    outputs: []const []const u8,
    failed: struct {
        /// derivations that failed to build
        builds: []const []const u8,
        /// derivations that have dependencies that failed
        dependents: []const []const u8,
    },

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        switch (self) {
            .outputs => |outputs| {
                for (outputs) |output| allocator.free(output);
                allocator.free(outputs);
            },
            .failed => |failed| {
                for (failed.builds) |drv| allocator.free(drv);
                allocator.free(failed.builds);

                for (failed.dependents) |drv| allocator.free(drv);
                allocator.free(failed.dependents);
            },
        }
    }
};

fn build(allocator: std.mem.Allocator, installables: []const []const u8) !BuildResult {
    log.debug("building {s}", .{installables});

    const argv = try std.mem.concat(allocator, []const u8, &.{
        &.{
            "nix",
            "build",
            "--restrict-eval",
            "--no-link",
            "--print-out-paths",
            "--quiet",
        },
        installables,
    });
    defer allocator.free(argv);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024 * 8,
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

    switch (result.term) {
        .Exited => |exited| switch (exited) {
            0 => {
                var iter = std.mem.tokenizeScalar(u8, result.stdout, '\n');
                while (iter.next()) |output| {
                    const output_dupe = try allocator.dupe(u8, output);
                    errdefer allocator.free(output_dupe);

                    try outputs.append(allocator, output_dupe);
                }
            },
            1 => {
                var builds = std.ArrayListUnmanaged([]const u8){};
                errdefer {
                    for (builds.items) |drv| allocator.free(drv);
                    builds.deinit(allocator);
                }

                var dependents = std.ArrayListUnmanaged([]const u8){};
                errdefer {
                    for (dependents.items) |drv| allocator.free(drv);
                    dependents.deinit(allocator);
                }

                var iter = std.mem.splitScalar(u8, result.stderr, '\n');
                while (iter.next()) |line| {
                    const readExpected = struct {
                        fn call(reader: anytype, comptime slice: []const u8) !bool {
                            var buf: [slice.len]u8 = undefined;
                            const len = reader.readAll(&buf) catch |err|
                                return if (err == error.EndOfStream) false else err;
                            return std.mem.eql(u8, buf[0..len], slice);
                        }
                    }.call;

                    builds: {
                        var line_stream = std.io.fixedBufferStream(line);
                        const line_reader = line_stream.reader();

                        var drv_list = std.ArrayListUnmanaged(u8){};
                        errdefer drv_list.deinit(allocator);

                        if (!try readExpected(line_reader, "error: builder for '")) break :builds;
                        line_reader.streamUntilDelimiter(drv_list.writer(allocator), '\'', null) catch break :builds;
                        if (!try readExpected(line_reader, " failed")) break :builds;

                        const drv = try drv_list.toOwnedSlice(allocator);
                        errdefer allocator.free(drv);

                        try builds.append(allocator, drv);
                    }

                    foreign_builds: {
                        var line_stream = std.io.fixedBufferStream(line);
                        const line_reader = line_stream.reader();

                        var drv_list = std.ArrayListUnmanaged(u8){};
                        errdefer drv_list.deinit(allocator);

                        if (!try readExpected(line_reader, "error: a '")) break :foreign_builds;
                        line_reader.streamUntilDelimiter(std.io.null_writer, '\'', null) catch break :foreign_builds;
                        if (!try readExpected(line_reader, " with features {")) break :foreign_builds;
                        line_reader.streamUntilDelimiter(std.io.null_writer, '}', null) catch break :foreign_builds;
                        if (!try readExpected(line_reader, " is required to build '")) break :foreign_builds;
                        line_reader.streamUntilDelimiter(drv_list.writer(allocator), '\'', null) catch break :foreign_builds;
                        if (!try readExpected(line_reader, ", but I am a '")) break :foreign_builds;
                        line_reader.streamUntilDelimiter(std.io.null_writer, '\'', null) catch break :foreign_builds;
                        if (!try readExpected(line_reader, " with features {")) break :foreign_builds;
                        line_reader.streamUntilDelimiter(std.io.null_writer, '}', null) catch break :foreign_builds;
                        if (line_reader.readByte() != error.EndOfStream) break :foreign_builds;

                        const drv = try drv_list.toOwnedSlice(allocator);
                        errdefer allocator.free(drv);

                        try builds.append(allocator, drv);
                    }

                    dependents: {
                        var line_stream = std.io.fixedBufferStream(line);
                        const line_reader = line_stream.reader();

                        var drv_list = std.ArrayListUnmanaged(u8){};
                        errdefer drv_list.deinit(allocator);

                        if (!try readExpected(line_reader, "error: ")) break :dependents;
                        line_reader.streamUntilDelimiter(std.io.null_writer, ' ', null) catch break :dependents;
                        if (!try readExpected(line_reader, "dependencies of derivation '")) break :dependents;
                        line_reader.streamUntilDelimiter(drv_list.writer(allocator), '\'', null) catch break :dependents;
                        if (!try readExpected(line_reader, " failed to build")) break :dependents;

                        const drv = try drv_list.toOwnedSlice(allocator);
                        errdefer allocator.free(drv);

                        try dependents.append(allocator, drv);
                    }
                }

                log.debug("build of {s} failed to build derivations {s} preventing builds {s}", .{ installables, builds.items, dependents.items });

                return .{ .failed = .{
                    .builds = try builds.toOwnedSlice(allocator),
                    .dependents = try dependents.toOwnedSlice(allocator),
                } };
            },
            else => log.debug("build of {s} exited with {d}", .{ installables, exited }),
        },
        else => |term| log.debug("build of {s} terminated with {}", .{ installables, term }),
    }

    if (outputs.items.len == 0) {
        log.debug("build of {s} failed: {s}", .{ installables, result.stderr });

        outputs.deinit(allocator);
        return .{ .failed = .{
            .builds = try allocator.alloc([]const u8, 0),
            .dependents = try allocator.alloc([]const u8, 0),
        } };
    }

    return .{ .outputs = try outputs.toOwnedSlice(allocator) };
}
