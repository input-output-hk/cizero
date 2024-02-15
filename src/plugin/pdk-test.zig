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
        .path = ":memory:",

        // in-memory databases only get `PRAGMA journal_mode = MEMORY`
        // which does not seem to work properly with multiple threads
        .size = 1,
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

test "on_timestamp" {
    var self = try init();
    defer self.deinit();

    try self.expectEqualStdio("",
        \\cizero.on_timestamp("pdk_test_on_timestamp_callback", 1000, 3000)
        \\
    , {}, struct {
        fn call(_: void, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_on_timestamp", &.{}, &.{}));
        }
    }.call);

    const SelectNext = Cizero.sql.queries.timeout_callback.SelectNext(&.{ .timestamp, .cron }, &.{ .plugin, .function, .user_data });
    const callback_row = blk: {
        const conn = self.cizero.registry.db_pool.acquire();
        defer self.cizero.registry.db_pool.release(conn);

        break :blk try SelectNext.row(conn, .{}) orelse return testing.expect(false);
    };
    errdefer callback_row.deinit();

    try testing.expectEqualStrings(pluginName(), SelectNext.column(callback_row, .@"callback.plugin"));

    var callback: Cizero.components.CallbackUnmanaged = undefined;
    try Cizero.sql.structFromRow(testing.allocator, &callback, callback_row, SelectNext.column, .{
        .func_name = .@"callback.function",
        .user_data = .@"callback.user_data",
    });
    defer callback.deinit(testing.allocator);

    {
        const user_data: [@sizeOf(i64)]u8 = @bitCast(self.cizero.components.timeout.mock_milli_timestamp.?.call(.{}));

        try testing.expectEqualStrings("pdk_test_on_timestamp_callback", callback.func_name);
        try testing.expect(callback.user_data != null);
        try testing.expectEqualSlices(u8, &user_data, callback.user_data.?);

        try testing.expectEqualDeep(3 * std.time.ms_per_s, SelectNext.column(callback_row, .timestamp));
        try testing.expect(SelectNext.column(callback_row, .cron) == null);
    }

    try callback_row.deinitErr();

    try self.expectEqualStdio("",
        \\pdk_test_on_timestamp_callback(1000)
        \\
    , callback, struct {
        fn call(cb: Cizero.components.CallbackUnmanaged, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try cb.run(testing.allocator, rt, &.{}, &.{}));
        }
    }.call);
}

test "on_cron" {
    var self = try init();
    defer self.deinit();

    try self.expectEqualStdio("",
        \\cizero.on_cron("pdk_test_on_cron_callback", "* * * * *", "* * * * *") 60000
        \\
    , {}, struct {
        fn call(_: void, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_on_cron", &.{}, &.{}));
        }
    }.call);

    const SelectNext = Cizero.sql.queries.timeout_callback.SelectNext(&.{ .timestamp, .cron }, &.{ .plugin, .function, .user_data });
    const callback_row = blk: {
        const conn = self.cizero.registry.db_pool.acquire();
        defer self.cizero.registry.db_pool.release(conn);

        break :blk try SelectNext.row(conn, .{}) orelse return testing.expect(false);
    };
    errdefer callback_row.deinit();

    var callback: Cizero.components.CallbackUnmanaged = undefined;
    try Cizero.sql.structFromRow(testing.allocator, &callback, callback_row, SelectNext.column, .{
        .func_name = .@"callback.function",
        .user_data = .@"callback.user_data",
    });
    defer callback.deinit(testing.allocator);

    try testing.expectEqualStrings("pdk_test_on_cron_callback", callback.func_name);
    try testing.expect(callback.user_data != null);
    try testing.expectEqualSlices(u8, "* * * * *", callback.user_data.?);

    try testing.expectEqualDeep(std.time.ms_per_min, SelectNext.column(callback_row, .timestamp));
    try testing.expect(SelectNext.column(callback_row, .cron) != null);
    try testing.expectEqualSlices(u8, "* * * * *", SelectNext.column(callback_row, .cron).?);

    try callback_row.deinitErr();

    try self.expectEqualStdio("",
        \\pdk_test_on_cron_callback("* * * * *")
        \\
    , callback, struct {
        fn call(cb: Cizero.components.CallbackUnmanaged, rt: Cizero.Runtime) anyerror!void {
            var outputs: [1]wasm.Value = undefined;
            try testing.expect(try cb.run(testing.allocator, rt, &.{}, &outputs));

            try testing.expectEqual(wasm.Value{ .i32 = @intFromBool(false) }, outputs[0]);
        }
    }.call);
}

test "exec" {
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
            try testing.expect(try rt.call("pdk_test_exec", &.{}, &.{}));
        }
    }.call);

    if (mock_child_run.exec_test_err) |err| return err;
}

test "on_webhook" {
    var self = try init();
    defer self.deinit();

    try self.expectEqualStdio("",
        \\cizero.on_webhook("pdk_test_on_webhook_callback", .{ 25, 372 })
        \\
    , {}, struct {
        fn call(_: void, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_on_webhook", &.{}, &.{}));
        }
    }.call);

    const SelectCallback = Cizero.sql.queries.http_callback.SelectCallbackByPlugin(&.{ .plugin, .function, .user_data });
    const callback_row = blk: {
        const conn = self.cizero.registry.db_pool.acquire();
        defer self.cizero.registry.db_pool.release(conn);

        break :blk try SelectCallback.row(conn, .{pluginName()}) orelse return testing.expect(false);
    };
    errdefer callback_row.deinit();

    var callback: Cizero.components.CallbackUnmanaged = undefined;
    try Cizero.sql.structFromRow(testing.allocator, &callback, callback_row, SelectCallback.column, .{
        .func_name = .function,
        .user_data = .user_data,
    });
    defer callback.deinit(testing.allocator);

    try testing.expectEqualStrings("pdk_test_on_webhook_callback", callback.func_name);
    try testing.expect(callback.user_data != null);
    try testing.expectEqualSlices(u8, &[_]u8{ 25, 116, 1 }, callback.user_data.?);

    try callback_row.deinitErr();

    {
        const req_body = "request body";

        try self.expectEqualStdio("",
            \\pdk_test_on_webhook_callback(.{ 25, 372 }, "
        ++ req_body ++
            \\")
            \\
        , callback, struct {
            fn call(cb: Cizero.components.CallbackUnmanaged, rt: Cizero.Runtime) anyerror!void {
                const linear = try rt.linearMemoryAllocator();
                const allocator = linear.allocator();

                const req_body_wasm = try allocator.dupeZ(u8, req_body);
                defer allocator.free(req_body_wasm);

                const res_status_wasm = try allocator.create(u16);
                defer allocator.destroy(res_status_wasm);
                res_status_wasm.* = 0;

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

test "nix_build" {
    var self = try init();
    defer self.deinit();

    const MockStartJobLoop = struct {
        const info = @typeInfo(@typeInfo(std.meta.fieldInfo(Cizero.components.Nix, .mock_start_job_loop).type).Optional.child.Fn).Fn;

        fn call(
            _: std.mem.Allocator,
            _: Cizero.components.Nix.Job,
        ) info.return_type.? {
            return false;
        }
    };

    self.cizero.components.nix.mock_start_job_loop = meta.disclosure(MockStartJobLoop.call, true);

    const MockLockFlakeUrl = struct {
        const info = @typeInfo(@typeInfo(std.meta.fieldInfo(Cizero.components.Nix, .mock_lock_flake_url).type).Optional.child.Fn).Fn;

        const input = "github:NixOS/nixpkgs/nixos-23.11#hello^out";
        const output = "github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e#hello^out";

        fn call(allocator: std.mem.Allocator, flake_url: []const u8) info.return_type.? {
            testing.expectEqualStrings(flake_url, input) catch return error.CouldNotLockFlake;
            return allocator.dupe(u8, output);
        }
    };

    self.cizero.components.nix.mock_lock_flake_url = meta.disclosure(MockLockFlakeUrl.call, true);

    try self.expectEqualStdio("",
        \\cizero.nix_build("pdk_test_nix_build_callback", null, "
    ++ MockLockFlakeUrl.input ++
        \\")
        \\
    , {}, struct {
        fn call(_: void, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_nix_build", &.{}, &.{}));
        }
    }.call);

    const SelectCallback = Cizero.sql.queries.nix_callback.SelectCallbackByAll(&.{ .plugin, .function, .user_data });
    const callback_row = blk: {
        const conn = self.cizero.registry.db_pool.acquire();
        defer self.cizero.registry.db_pool.release(conn);

        break :blk try SelectCallback.row(conn, .{ MockLockFlakeUrl.output, null, @intFromEnum(Cizero.components.Nix.Job.OutputFormat.raw), true }) orelse return testing.expect(false);
    };
    errdefer callback_row.deinit();

    var callback: Cizero.components.CallbackUnmanaged = undefined;
    try Cizero.sql.structFromRow(testing.allocator, &callback, callback_row, SelectCallback.column, .{
        .func_name = .function,
        .user_data = .user_data,
    });
    defer callback.deinit(testing.allocator);

    try testing.expectEqualStrings("pdk_test_nix_build_callback", callback.func_name);
    try testing.expect(callback.user_data == null);

    try callback_row.deinitErr();

    const store_drv_output = "/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-example";
    const store_drv = store_drv_output ++ ".drv";

    try self.expectEqualStdio("",
        \\pdk_test_nix_build_callback(null, 0, "
    ++ MockLockFlakeUrl.output ++
        \\", "
    ++ store_drv ++
        \\", {
    ++ " " ++ store_drv_output ++
        \\ }, null)
        \\
    , callback, struct {
        fn call(cb: Cizero.components.CallbackUnmanaged, rt: Cizero.Runtime) anyerror!void {
            const linear = try rt.linearMemoryAllocator();
            const allocator = linear.allocator();

            const flake_url_wasm = try allocator.dupeZ(u8, MockLockFlakeUrl.output);
            defer allocator.free(flake_url_wasm);

            const store_drv_wasm = try allocator.dupeZ(u8, store_drv);
            defer allocator.free(store_drv_wasm);

            const store_drv_output_wasm = try allocator.dupeZ(u8, store_drv_output);
            defer allocator.free(store_drv_output_wasm);

            var store_drv_outputs_wasm = try allocator.alloc(wasm.usize, 1);
            defer allocator.free(store_drv_outputs_wasm);
            store_drv_outputs_wasm[0] = linear.memory.offset(store_drv_output_wasm.ptr);

            try testing.expect(try cb.run(testing.allocator, rt, &[_]wasm.Value{
                .{ .i32 = @intCast(linear.memory.offset(flake_url_wasm.ptr)) },
                .{ .i32 = @intCast(linear.memory.offset(store_drv_wasm.ptr)) },
                .{ .i32 = @intCast(linear.memory.offset(store_drv_outputs_wasm.ptr)) },
                .{ .i32 = @intCast(store_drv_outputs_wasm.len) },
                .{ .i32 = 0 },
            }, &.{}));
        }
    }.call);
}

test "nix_eval" {
    var self = try init();
    defer self.deinit();

    const MockStartJobLoop = struct {
        const info = @typeInfo(@typeInfo(std.meta.fieldInfo(Cizero.components.Nix, .mock_start_job_loop).type).Optional.child.Fn).Fn;

        fn call(
            _: std.mem.Allocator,
            _: Cizero.components.Nix.Job,
        ) info.return_type.? {
            return false;
        }
    };

    self.cizero.components.nix.mock_start_job_loop = meta.disclosure(MockStartJobLoop.call, true);

    const MockLockFlakeUrl = struct {
        const info = @typeInfo(@typeInfo(std.meta.fieldInfo(Cizero.components.Nix, .mock_lock_flake_url).type).Optional.child.Fn).Fn;

        const input = "github:NixOS/nixpkgs/nixos-23.11#hello";
        const output = "github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e#hello";

        fn call(allocator: std.mem.Allocator, flake_url: []const u8) info.return_type.? {
            testing.expectEqualStrings(flake_url, input) catch return error.CouldNotLockFlake;
            return allocator.dupe(u8, output);
        }
    };

    self.cizero.components.nix.mock_lock_flake_url = meta.disclosure(MockLockFlakeUrl.call, true);

    const expression = "hello: hello.meta.description";

    try self.expectEqualStdio("",
        \\cizero.nix_eval("pdk_test_nix_eval_callback", null, "
    ++ MockLockFlakeUrl.input ++
        \\", "
    ++ expression ++
        \\", .raw)
        \\
    , {}, struct {
        fn call(_: void, rt: Cizero.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_nix_eval", &.{}, &.{}));
        }
    }.call);

    const SelectCallback = Cizero.sql.queries.nix_callback.SelectCallbackByAll(&.{ .plugin, .function, .user_data });
    const callback_row = blk: {
        const conn = self.cizero.registry.db_pool.acquire();
        defer self.cizero.registry.db_pool.release(conn);

        break :blk try SelectCallback.row(conn, .{ MockLockFlakeUrl.output, expression, @intFromEnum(Cizero.components.Nix.Job.OutputFormat.raw), false }) orelse return testing.expect(false);
    };
    errdefer callback_row.deinit();

    var callback: Cizero.components.CallbackUnmanaged = undefined;
    try Cizero.sql.structFromRow(testing.allocator, &callback, callback_row, SelectCallback.column, .{
        .func_name = .function,
        .user_data = .user_data,
    });
    defer callback.deinit(testing.allocator);

    try testing.expectEqualStrings("pdk_test_nix_eval_callback", callback.func_name);
    try testing.expect(callback.user_data == null);

    try callback_row.deinitErr();

    const result = "A program that produces a familiar, friendly greeting";

    try self.expectEqualStdio("",
        \\pdk_test_nix_eval_callback(null, 0, "
    ++ MockLockFlakeUrl.output ++
        \\", "
    ++ result ++
        \\", null)
        \\
    , callback, struct {
        fn call(cb: Cizero.components.CallbackUnmanaged, rt: Cizero.Runtime) anyerror!void {
            const linear = try rt.linearMemoryAllocator();
            const allocator = linear.allocator();

            const flake_url_wasm = try allocator.dupeZ(u8, MockLockFlakeUrl.output);
            defer allocator.free(flake_url_wasm);

            const result_wasm = try allocator.dupeZ(u8, result);
            defer allocator.free(result_wasm);

            try testing.expect(try cb.run(testing.allocator, rt, &[_]wasm.Value{
                .{ .i32 = @intCast(linear.memory.offset(flake_url_wasm.ptr)) },
                .{ .i32 = @intCast(linear.memory.offset(result_wasm.ptr)) },
                .{ .i32 = 0 },
            }, &.{}));
        }
    }.call);
}
