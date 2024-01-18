const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

const components = @import("../components.zig");
const mem = @import("../mem.zig");
const meta = @import("../meta.zig");
const wasm = @import("../wasm.zig");

const Cizero = @import("../Cizero.zig");
const Plugin = @import("../Plugin.zig");

cizero: *Cizero,
plugin: Plugin,

fn deinit(self: *@This()) void {
    self.cizero.registry.wasi_config.env.?.env.deinit(testing.allocator);
    self.cizero.deinit();
}

fn init() !@This() {
    var cizero = try Cizero.init(testing.allocator);
    errdefer cizero.deinit();

    cizero.registry.wasi_config = .{
        .env = .{ .env = try meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged([]const u8), testing.allocator, .{
            .CIZERO_PDK_TEST = "",
        }) },
    };

    cizero.components.timeout.mock_milli_timestamp = meta.disclosure(struct {
        fn call() i64 {
            return std.time.ms_per_s;
        }
    }.call, true);

    cizero.components.process.mock_child_exec = meta.disclosure(struct {
        const info = @typeInfo(@TypeOf(std.process.Child.exec)).Fn;

        fn call(_: info.params[0].type.?) info.return_type.? {
            return error.Unexpected;
        }
    }.call, true);

    const plugin = .{ .path = build_options.plugin_path };
    _ = try cizero.registry.registerPlugin(plugin);

    return .{
        .cizero = cizero,
        .plugin = plugin,
    };
}

fn runtime(self: @This()) !Plugin.Runtime {
    return self.cizero.registry.runtime(self.plugin.name());
}

fn expectEqualStdio(
    self: @This(),
    stdout: []const u8,
    stderr: []const u8,
    run_fn_ctx: anytype,
    run_fn: fn (@TypeOf(run_fn_ctx), Plugin.Runtime) anyerror!void,
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
        fn call(_: void, rt: Plugin.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_on_timestamp", &.{}, &.{}));
        }
    }.call);

    const Callback = @TypeOf(self.cizero.components.timeout.plugin_callbacks).Callback;
    const callback = blk: {
        var iter = self.cizero.components.timeout.plugin_callbacks.iterator();
        const entry = iter.next().?;
        try testing.expect(iter.next() == null);

        std.debug.assert(std.mem.eql(u8, self.plugin.name(), entry.pluginName()));

        break :blk entry.callbackPtr();
    };

    {
        const user_data: [@sizeOf(i64)]u8 = @bitCast(self.cizero.components.timeout.mock_milli_timestamp.?.call(.{}));

        try testing.expectEqualStrings("pdk_test_on_timestamp_callback", callback.func_name);
        try testing.expect(callback.user_data != null);
        try testing.expectEqualSlices(u8, &user_data, callback.user_data.?);
        try testing.expectEqualDeep(Callback.Condition{ .timestamp = 3 * std.time.ms_per_s }, callback.condition);
    }

    try self.expectEqualStdio("",
        \\pdk_test_on_timestamp_callback(1000)
        \\
    , callback, struct {
        fn call(cb: *const Callback, rt: Plugin.Runtime) anyerror!void {
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
        fn call(_: void, rt: Plugin.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_on_cron", &.{}, &.{}));
        }
    }.call);

    const Callback = @TypeOf(self.cizero.components.timeout.plugin_callbacks).Callback;
    const callback = blk: {
        var iter = self.cizero.components.timeout.plugin_callbacks.iterator();
        const entry = iter.next().?;
        try testing.expect(iter.next() == null);

        std.debug.assert(std.mem.eql(u8, self.plugin.name(), entry.pluginName()));

        break :blk entry.callbackPtr();
    };

    try testing.expectEqualStrings("pdk_test_on_cron_callback", callback.func_name);
    try testing.expect(callback.user_data != null);
    try testing.expectEqualSlices(u8, "* * * * *", callback.user_data.?);
    try testing.expectEqual(Callback.Condition.cron, callback.condition);

    {
        const Cron = @import("cron").Cron;
        const Datetime = @import("datetime").datetime.Datetime;

        var cron = Cron.init();
        try cron.parse("* * * * *");
        const now = Datetime.fromTimestamp(self.cizero.components.timeout.mock_milli_timestamp.?.call(.{}));

        try testing.expect((try cron.next(now)).eql(try callback.condition.cron.next(now)));
        try testing.expect((try cron.previous(now)).eql(try callback.condition.cron.previous(now)));
    }

    try self.expectEqualStdio("",
        \\pdk_test_on_cron_callback("* * * * *")
        \\
    , callback, struct {
        fn call(cb: *const Callback, rt: Plugin.Runtime) anyerror!void {
            var outputs: [1]wasm.Value = undefined;
            try testing.expect(try cb.run(testing.allocator, rt, &.{}, &outputs));
            try testing.expectEqual(wasm.Value{ .i32 = @intFromBool(false) }, outputs[0]);
        }
    }.call);
}

test "exec" {
    var self = try init();
    defer self.deinit();

    const MockChildExec = struct {
        exec_test_err: ?anyerror = null,

        pub const stdout = "stdout";
        pub const stderr = "stderr $foo=bar";

        const info = @typeInfo(@TypeOf(std.process.Child.exec)).Fn;

        pub fn exec(mock: *@This(), args: info.params[0].type.?) info.return_type.? {
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
    var mock_child_exec = MockChildExec{};

    self.cizero.components.process.mock_child_exec = meta.closure(MockChildExec.exec, &mock_child_exec);

    try self.expectEqualStdio("",
        \\term tag: Exited
        \\term code: 0
        \\stdout:
    ++ " " ++ MockChildExec.stdout ++
        \\
        \\stderr:
    ++ " " ++ MockChildExec.stderr ++
        \\
        \\
    , {}, struct {
        fn call(_: void, rt: Plugin.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_exec", &.{}, &.{}));
        }
    }.call);

    if (mock_child_exec.exec_test_err) |err| return err;
}

test "on_webhook" {
    var self = try init();
    defer self.deinit();

    try self.expectEqualStdio("",
        \\cizero.on_webhook("pdk_test_on_webhook_callback", .{ 25, 372 })
        \\
    , {}, struct {
        fn call(_: void, rt: Plugin.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_on_webhook", &.{}, &.{}));
        }
    }.call);

    const Callback = @TypeOf(self.cizero.components.http.plugin_callbacks).Callback;
    const callback = blk: {
        var iter = self.cizero.components.http.plugin_callbacks.iterator();
        const entry = iter.next().?;
        try testing.expect(iter.next() == null);

        std.debug.assert(std.mem.eql(u8, self.plugin.name(), entry.pluginName()));

        break :blk entry.callbackPtr();
    };

    try testing.expectEqualStrings("pdk_test_on_webhook_callback", callback.func_name);
    try testing.expect(callback.user_data != null);
    try testing.expectEqualSlices(u8, &[_]u8{ 25, 116, 1 }, callback.user_data.?);
    try testing.expectEqualDeep(Callback.Condition.webhook, callback.condition);

    {
        const body = "body";

        try self.expectEqualStdio("",
            \\pdk_test_on_webhook_callback(.{ 25, 372 }, "
        ++ body ++
            \\")
            \\
        , callback, struct {
            fn call(cb: *const Callback, rt: Plugin.Runtime) anyerror!void {
                const linear = try rt.linearMemoryAllocator();
                const allocator = linear.allocator();

                const body_wasm = try allocator.dupeZ(u8, body);
                defer allocator.free(body_wasm);

                var outputs: [1]wasm.Value = undefined;
                try testing.expect(try cb.run(testing.allocator, rt, &[_]wasm.Value{.{ .i32 = @intCast(linear.memory.offset(body_wasm.ptr)) }}, &outputs));
                try testing.expectEqual(wasm.Value{ .i32 = @intFromBool(false) }, outputs[0]);
            }
        }.call);
    }
}

test "nix_build" {
    var self = try init();
    defer self.deinit();

    const MockStartBuildLoop = struct {
        allocator: std.mem.Allocator,
        flake_url: []const u8,
        plugin_name: []const u8,
        callback: components.Nix.Callback,

        const info = @typeInfo(@typeInfo(std.meta.fieldInfo(components.Nix, .mock_start_build_loop).type).Optional.child.Fn).Fn;

        fn call(
            ctx: *@This(),
            allocator: std.mem.Allocator,
            flake_url: []const u8,
            plugin_name: []const u8,
            callback: components.Nix.Callback,
        ) info.return_type.? {
            ctx.* = .{
                .allocator = allocator,
                .flake_url = flake_url,
                .plugin_name = plugin_name,
                .callback = callback,
            };
        }
    };
    var mock_start_build_loop: MockStartBuildLoop = undefined;
    defer {
        var ctx = &mock_start_build_loop;
        ctx.allocator.free(ctx.flake_url);
        ctx.callback.deinit(ctx.allocator);
    }

    self.cizero.components.nix.mock_start_build_loop = meta.closure(MockStartBuildLoop.call, &mock_start_build_loop);

    const MockLockFlakeUrl = struct {
        const info = @typeInfo(@typeInfo(std.meta.fieldInfo(components.Nix, .mock_lock_flake_url).type).Optional.child.Fn).Fn;

        const input = "github:NixOS/nixpkgs/nixos-23.11#hello^out";
        const output = "github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e#hello^out";

        fn call(allocator: std.mem.Allocator, flake_url: []const u8) info.return_type.? {
            if (!std.mem.eql(u8, flake_url, input)) return error.CouldNotLockFlake;
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
        fn call(_: void, rt: Plugin.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_nix_build", &.{}, &.{}));
        }
    }.call);

    try testing.expectEqualStrings("pdk_test_nix_build_callback", mock_start_build_loop.callback.func_name);
    try testing.expect(mock_start_build_loop.callback.user_data == null);
    try testing.expectEqualStrings(MockLockFlakeUrl.output, mock_start_build_loop.flake_url);

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
    , &mock_start_build_loop.callback, struct {
        fn call(cb: *const components.Nix.Callback, rt: Plugin.Runtime) anyerror!void {
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
