const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

const Cizero = @import("cizero");
const lib = @import("lib");
const meta = lib.meta;
const wasm = lib.wasm;

fn pluginName() []const u8 {
    return std.fs.path.stem(build_options.plugin_path);
}

cizero: *Cizero,

fn deinit(self: *@This()) void {
    self.cizero.registry.wasi_config.env.?.env.deinit(testing.allocator);
    self.cizero.deinit();
}

fn init() !@This() {
    var cizero = try Cizero.init(testing.allocator, .{
        .db = .{
            .path = ":memory:",

            // in-memory databases only get `PRAGMA journal_mode = MEMORY`
            // which does not seem to work properly with multiple threads
            .size = 1,
        },
    });
    errdefer cizero.deinit();

    cizero.registry.wasi_config = .{
        .env = .{ .env = try meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged([]const u8), testing.allocator, .{
            .CIZERO_PDK_TEST = "",
        }) },
    };
    errdefer cizero.registry.wasi_config.env.?.env.deinit(testing.allocator);

    cizero.components.timeout.mock_milli_timestamp = meta.disclosure(struct {
        fn call() i64 {
            return std.time.ms_per_s;
        }
    }.call, true);

    cizero.components.process.mock_child_run = meta.disclosure(struct {
        const info = @typeInfo(@TypeOf(std.process.Child.run)).Fn;

        fn call(_: info.params[0].type.?) info.return_type.? {
            return error.Unexpected;
        }
    }.call, true);

    const plugin_wasm = try std.fs.cwd().readFileAlloc(testing.allocator, build_options.plugin_path, std.math.maxInt(usize));
    defer testing.allocator.free(plugin_wasm);

    _ = try cizero.registry.registerPlugin(pluginName(), plugin_wasm);

    return .{ .cizero = cizero };
}

fn runtime(self: @This()) !Cizero.Runtime {
    return self.cizero.registry.runtime(pluginName());
}

fn expectEqualStdio(
    self: @This(),
    stdout: []const u8,
    stderr: []const u8,
    run_fn_ctx: anytype,
    run_fn: fn (@TypeOf(run_fn_ctx), Cizero.Runtime) anyerror!void,
) !void {
    var rt = try self.runtime();
    defer rt.deinit();

    var wasi_config = self.cizero.registry.wasi_config;
    const collect_output = try wasi_config.collectOutput(testing.allocator);
    defer collect_output.deinit();
    rt.wasi_config = &wasi_config;

    try run_fn(run_fn_ctx, rt);

    const output = try collect_output.collect(std.math.maxInt(usize));
    defer output.deinit();

    try testing.expectEqualStrings(stdout, output.stdout);
    try testing.expectEqualStrings(stderr, output.stderr);
}

test "timeout_on_timestamp" {
    var self = try init();
    defer self.deinit();

    try self.expectEqualStdio("",
        \\1000
        \\3000
        \\
    , {}, struct {
        fn call(_: void, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_timeout_on_timestamp", &.{}, &.{}));
        }
    }.call);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    const callback_row = row: {
        const conn = self.cizero.registry.db_pool.acquire();
        defer self.cizero.registry.db_pool.release(conn);

        break :row try Cizero.sql.queries.TimeoutCallback.SelectNext(&.{ .timestamp, .cron }, &.{ .plugin, .function, .user_data })
            .query(arena_allocator, conn, .{}) orelse return testing.expect(false);
    };

    try testing.expectEqualStrings(pluginName(), callback_row.@"callback.plugin");

    const callback = Cizero.components.CallbackUnmanaged{
        .func_name = try arena_allocator.dupeZ(u8, callback_row.@"callback.function"),
        .user_data = if (callback_row.@"callback.user_data") |ud| ud.value else null,
    };

    try testing.expect(callback.user_data != null);

    try testing.expectEqualDeep(3 * std.time.ms_per_s, callback_row.timestamp);
    try testing.expect(callback_row.cron == null);

    try self.expectEqualStdio("",
        \\1000
        \\
    , callback, struct {
        fn call(cb: Cizero.components.CallbackUnmanaged, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try cb.run(testing.allocator, rt, &.{}, &.{}));
        }
    }.call);
}

test "timeout_on_cron" {
    var self = try init();
    defer self.deinit();

    try self.expectEqualStdio("",
        \\* * * * *
        \\* * * * *
        \\60000
        \\
    , {}, struct {
        fn call(_: void, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_timeout_on_cron", &.{}, &.{}));
        }
    }.call);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    const callback_row = row: {
        const conn = self.cizero.registry.db_pool.acquire();
        defer self.cizero.registry.db_pool.release(conn);

        break :row try Cizero.sql.queries.TimeoutCallback.SelectNext(&.{ .timestamp, .cron }, &.{ .plugin, .function, .user_data })
            .query(arena_allocator, conn, .{}) orelse return testing.expect(false);
    };

    const callback = Cizero.components.CallbackUnmanaged{
        .func_name = try arena_allocator.dupeZ(u8, callback_row.@"callback.function"),
        .user_data = if (callback_row.@"callback.user_data") |ud| ud.value else null,
    };

    try testing.expect(callback.user_data != null);

    try testing.expectEqualDeep(std.time.ms_per_min, callback_row.timestamp);
    try testing.expect(callback_row.cron != null);
    try testing.expectEqualSlices(u8, "* * * * *", callback_row.cron.?);

    try self.expectEqualStdio("",
        \\* * * * *
        \\
    , callback, struct {
        fn call(cb: Cizero.components.CallbackUnmanaged, rt: Cizero.Runtime) anyerror!void {
            var outputs: [1]wasm.Value = undefined;
            try testing.expect(try cb.run(testing.allocator, rt, &.{}, &outputs));

            try testing.expectEqual(wasm.Value{ .i32 = @intFromBool(false) }, outputs[0]);
        }
    }.call);
}

test "process_exec" {
    var self = try init();
    defer self.deinit();

    const MockChildRun = struct {
        exec_test_err: ?anyerror = null,

        pub const stdout = "stdout";
        pub const stderr = "stderr $foo=bar";

        const info = @typeInfo(@TypeOf(std.process.Child.run)).Fn;

        pub fn run(mock: *@This(), args: info.params[0].type.?) info.return_type.? {
            execTest(args) catch |err| {
                mock.exec_test_err = err;
                if (@errorReturnTrace()) |trace| trace.format("", .{}, std.io.getStdErr().writer()) catch unreachable;
            };

            const stdout_dupe = try args.allocator.dupe(u8, stdout);
            errdefer args.allocator.free(stdout_dupe);

            const stderr_dupe = try args.allocator.dupe(u8, stderr);
            errdefer args.allocator.free(stderr_dupe);

            return .{
                .term = .{ .Exited = 0 },
                .stdout = stdout_dupe,
                .stderr = stderr_dupe,
            };
        }

        fn execTest(args: info.params[0].type.?) !void {
            inline for (.{
                "sh", "-c",
                \\echo     stdout
                \\echo >&2 stderr \$foo="$foo"
            }, args.argv) |expected, actual|
                try testing.expectEqualStrings(expected, actual);

            try testing.expect(args.env_map != null);
            try testing.expectEqual(@as(std.process.EnvMap.Size, 1), args.env_map.?.count());
            {
                const foo = args.env_map.?.get("foo");
                try testing.expect(foo != null);
                try testing.expectEqualStrings("bar", foo.?);
            }

            try testing.expect(args.cwd == null);
            try testing.expect(args.cwd_dir == null);

            try testing.expectEqual(@as(usize, 50 * 1024), args.max_output_bytes);

            try testing.expectEqual(std.process.Child.Arg0Expand.no_expand, args.expand_arg0);
        }
    };
    var mock_child_run = MockChildRun{};

    self.cizero.components.process.mock_child_run = meta.closure(MockChildRun.run, &mock_child_run);

    try self.expectEqualStdio("",
        \\term tag: Exited
        \\term code: 0
        \\stdout:
    ++ " " ++ MockChildRun.stdout ++
        \\
        \\stderr:
    ++ " " ++ MockChildRun.stderr ++
        \\
        \\
    , {}, struct {
        fn call(_: void, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_process_exec", &.{}, &.{}));
        }
    }.call);

    if (mock_child_run.exec_test_err) |err| return err;
}

test "http_on_webhook" {
    var self = try init();
    defer self.deinit();

    try self.expectEqualStdio("",
        \\.{ 25, 372 }
        \\
    , {}, struct {
        fn call(_: void, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_http_on_webhook", &.{}, &.{}));
        }
    }.call);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    const callback_row = row: {
        const conn = self.cizero.registry.db_pool.acquire();
        defer self.cizero.registry.db_pool.release(conn);

        break :row try Cizero.sql.queries.HttpCallback.SelectCallbackByPlugin(&.{ .plugin, .function, .user_data })
            .query(arena_allocator, conn, .{pluginName()}) orelse
            return testing.expect(false);
    };

    const callback = Cizero.components.CallbackUnmanaged{
        .func_name = try arena_allocator.dupeZ(u8, callback_row.function),
        .user_data = if (callback_row.user_data) |ud| ud.value else null,
    };

    try testing.expect(callback.user_data != null);

    {
        const req_body = "request body";

        try self.expectEqualStdio("",
            \\.{ 25, 372 }
            \\
        ++ req_body ++
            \\
            \\
        , callback, struct {
            fn call(cb: Cizero.components.CallbackUnmanaged, rt: Cizero.Runtime) anyerror!void {
                const linear = try rt.linearMemoryAllocator();
                const allocator = linear.allocator();

                const req_body_wasm = try allocator.dupeZ(u8, req_body);
                defer allocator.free(req_body_wasm);

                const res_status_wasm = try allocator.create(u16);
                defer allocator.destroy(res_status_wasm);
                res_status_wasm.* = 204;

                const res_body_addr = try allocator.create(wasm.usize);
                defer allocator.destroy(res_body_addr);
                res_body_addr.* = 0;

                var outputs: [1]wasm.Value = undefined;

                try testing.expect(try cb.run(testing.allocator, rt, &[_]wasm.Value{
                    .{ .i32 = @intCast(linear.memory.offset(req_body_wasm.ptr)) },
                    .{ .i32 = @intCast(linear.memory.offset(res_status_wasm)) },
                    .{ .i32 = @intCast(linear.memory.offset(res_body_addr)) },
                }, &outputs));
                try testing.expectEqual(wasm.Value{ .i32 = @intFromBool(false) }, outputs[0]);

                try testing.expectEqual(200, res_status_wasm.*);
                try testing.expect(res_body_addr.* != 0);
                try testing.expectEqualStrings("response body", wasm.span(linear.memory.slice(), res_body_addr.*));
            }
        }.call);
    }
}

test "nix_on_build" {
    var self = try init();
    defer self.deinit();

    const MockStartJob = struct {
        const info = @typeInfo(@typeInfo(std.meta.fieldInfo(Cizero.components.Nix, .mock_start_job).type).Optional.child.Fn).Fn;

        fn call(
            _: std.mem.Allocator,
            _: Cizero.components.Nix.Job,
        ) info.return_type.? {
            return false;
        }
    };

    self.cizero.components.nix.mock_start_job = meta.disclosure(MockStartJob.call, true);

    const installable = "/nix/store/g2mxdrkwr1hck4y5479dww7m56d1x81v-hello-2.12.1.drv^*";
    const installable_output = "/nix/store/sbldylj3clbkc0aqvjjzfa6slp4zdvlj-hello-2.12.1";

    try self.expectEqualStdio("",
        \\void
        \\{
    ++ " " ++ installable ++
        \\ }
        \\
    , {}, struct {
        fn call(_: void, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_nix_on_build", &.{}, &.{}));
        }
    }.call);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    const callback_row = row: {
        const conn = self.cizero.registry.db_pool.acquire();
        defer self.cizero.registry.db_pool.release(conn);

        const installables = try Cizero.sql.queries.NixBuildCallback.encodeInstallables(testing.allocator, &.{installable});
        defer testing.allocator.free(installables);

        const rows = try Cizero.sql.queries.NixBuildCallback.SelectCallbackByInstallables(&.{ .plugin, .function, .user_data })
            .query(arena_allocator, conn, .{installables});

        try testing.expectEqual(1, rows.len);

        break :row rows[0];
    };

    const callback = Cizero.components.CallbackUnmanaged{
        .func_name = try arena_allocator.dupeZ(u8, callback_row.function),
        .user_data = if (callback_row.user_data) |ud| ud.value else null,
    };

    try self.expectEqualStdio("",
        \\void
        \\{
    ++ " " ++ installable_output ++
        \\ }
        \\null
        \\null
        \\
    , callback, struct {
        fn call(cb: Cizero.components.CallbackUnmanaged, rt: Cizero.Runtime) anyerror!void {
            const linear = try rt.linearMemoryAllocator();
            const allocator = linear.allocator();

            const store_drv_output_wasm = try allocator.dupeZ(u8, installable_output);
            defer allocator.free(store_drv_output_wasm);

            var store_drv_outputs_wasm = try allocator.alloc(wasm.usize, 1);
            defer allocator.free(store_drv_outputs_wasm);
            store_drv_outputs_wasm[0] = linear.memory.offset(store_drv_output_wasm.ptr);

            try testing.expect(try cb.run(testing.allocator, rt, &[_]wasm.Value{
                .{ .i32 = @intCast(linear.memory.offset(store_drv_outputs_wasm.ptr)) },
                .{ .i32 = @intCast(store_drv_outputs_wasm.len) },
                .{ .i32 = 0 },
                .{ .i32 = 0 },
                .{ .i32 = 0 },
                .{ .i32 = 0 },
            }, &.{}));
        }
    }.call);
}

test "nix_on_eval" {
    var self = try init();
    defer self.deinit();

    const MockStartJob = struct {
        const info = @typeInfo(@typeInfo(std.meta.fieldInfo(Cizero.components.Nix, .mock_start_job).type).Optional.child.Fn).Fn;

        fn call(
            _: std.mem.Allocator,
            _: Cizero.components.Nix.Job,
        ) info.return_type.? {
            return false;
        }
    };

    self.cizero.components.nix.mock_start_job = meta.disclosure(MockStartJob.call, true);

    const flake = "github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e";
    const expr = "flake: flake.legacyPackages.x86_64-linux.hello.meta.description";

    try self.expectEqualStdio("",
        \\void
        \\
    ++ flake ++
        \\
        \\
    ++ expr ++
        \\
        \\raw
        \\
    , {}, struct {
        fn call(_: void, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_nix_on_eval", &.{}, &.{}));
        }
    }.call);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    const callback_row = row: {
        const conn = self.cizero.registry.db_pool.acquire();
        defer self.cizero.registry.db_pool.release(conn);

        const rows = try Cizero.sql.queries.NixEvalCallback.SelectCallbackByFlakeAndExprAndFormat(&.{ .plugin, .function, .user_data })
            .query(arena_allocator, conn, .{ flake, expr, @intFromEnum(Cizero.components.Nix.EvalFormat.raw) });

        try testing.expectEqual(1, rows.len);

        break :row rows[0];
    };

    const callback = Cizero.components.CallbackUnmanaged{
        .func_name = try arena_allocator.dupeZ(u8, callback_row.function),
        .user_data = if (callback_row.user_data) |ud| ud.value else null,
    };

    const result = "A program that produces a familiar, friendly greeting";

    try self.expectEqualStdio("",
        \\void
        \\
    ++ result ++
        \\
        \\null
        \\null
        \\null
        \\
    , callback, struct {
        fn call(cb: Cizero.components.CallbackUnmanaged, rt: Cizero.Runtime) anyerror!void {
            const linear = try rt.linearMemoryAllocator();
            const allocator = linear.allocator();

            const result_wasm = try allocator.dupeZ(u8, result);
            defer allocator.free(result_wasm);

            try testing.expect(try cb.run(testing.allocator, rt, &[_]wasm.Value{
                .{ .i32 = @intCast(linear.memory.offset(result_wasm.ptr)) },
                .{ .i32 = 0 },
                .{ .i32 = 0 },
                .{ .i32 = 0 },
                .{ .i32 = 0 },
                .{ .i32 = 0 },
            }, &.{}));
        }
    }.call);
}
