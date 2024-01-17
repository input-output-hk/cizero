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

const Mocks = struct {
    timeout: struct {
        milli_timestamp: meta.Closure(fn () i64, true) = meta.disclosure(struct {
            fn call() i64 {
                return std.time.ms_per_s;
            }
        }.call, true),
    } = .{},

    process: struct {
        const Exec = @TypeOf(std.process.Child.exec);

        exec: meta.Closure(Exec, true) = meta.disclosure(struct {
            const info = @typeInfo(Exec).Fn;

            fn call(_: info.params[0].type.?) info.return_type.? {
                return error.Unexpected;
            }
        }.call, true),
    } = .{},

    nix: struct {
        const MockLockFlakeUrl = std.meta.fieldInfo(components.Nix, .mock_lock_flake_url).type;

        const lock_flake_url_input = "github:NixOS/nixpkgs/nixos-23.11#hello^out";
        const lock_flake_url_output = "github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e#hello^out";

        const MockStartBuildLoop = std.meta.fieldInfo(components.Nix, .mock_start_build_loop).type;

        lock_flake_url: MockLockFlakeUrl = meta.disclosure(struct {
            const info = @typeInfo(std.meta.Child(MockLockFlakeUrl).Fn).Fn;

            fn call(allocator: std.mem.Allocator, flake_url: []const u8) info.return_type.? {
                if (!std.mem.eql(u8, flake_url, lock_flake_url_input)) return error.CouldNotLockFlake;
                return allocator.dupe(u8, lock_flake_url_output);
            }
        }.call, true),

        start_build_loop: MockStartBuildLoop = null,
    } = .{},
};

fn deinit(self: *@This()) void {
    self.cizero.registry.wasi_config.env.?.env.deinit(testing.allocator);
    self.cizero.deinit();
}

fn init(mocks: Mocks) !@This() {
    var cizero = try Cizero.init(testing.allocator);
    errdefer cizero.deinit();

    cizero.registry.wasi_config = .{
        .env = .{ .env = try meta.hashMapFromStruct(std.StringArrayHashMapUnmanaged([]const u8), testing.allocator, .{
            .CIZERO_PDK_TEST = "",
        }) },
    };

    cizero.components.timeout.mock_milli_timestamp = mocks.timeout.milli_timestamp;
    cizero.components.process.mock_child_exec = mocks.process.exec;
    cizero.components.nix.mock_lock_flake_url = mocks.nix.lock_flake_url;
    cizero.components.nix.mock_start_build_loop = mocks.nix.start_build_loop;

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
    const mocks = Mocks{};

    var self = try init(mocks);
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
        const user_data: [@sizeOf(i64)]u8 = @bitCast(mocks.timeout.milli_timestamp.call(.{}));

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
    const mocks = Mocks{};

    var self = try init(mocks);
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
        const now = Datetime.fromTimestamp(mocks.timeout.milli_timestamp.call(.{}));

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
    var mocks = struct {
        process: struct {
            exec_test_err: ?anyerror = null,

            pub const stdout = "stdout";
            pub const stderr = "stderr $foo=bar";

            const info = @typeInfo(@TypeOf(std.process.Child.exec)).Fn;

            pub fn exec(self: *@This(), args: info.params[0].type.?) info.return_type.? {
                execTest(args) catch |err| {
                    self.exec_test_err = err;
                    if (@errorReturnTrace()) |trace| trace.format("", .{}, std.io.getStdErr().writer()) catch unreachable;
                };

                return .{
                    .term = .{ .Exited = 0 },
                    .stdout = try args.allocator.dupe(u8, stdout),
                    .stderr = try args.allocator.dupe(u8, stderr),
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
        } = .{},
    }{};

    var self = try init(.{
        .process = .{ .exec = meta.closure(@TypeOf(mocks.process).exec, &mocks.process) },
    });
    defer self.deinit();

    try self.expectEqualStdio("",
        \\term tag: Exited
        \\term code: 0
        \\stdout:
    ++ " " ++ @TypeOf(mocks.process).stdout ++
        \\
        \\stderr:
    ++ " " ++ @TypeOf(mocks.process).stderr ++
        \\
        \\
    , {}, struct {
        fn call(_: void, rt: Plugin.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_exec", &.{}, &.{}));
        }
    }.call);

    if (mocks.process.exec_test_err) |err| return err;
}

test "on_webhook" {
    const mocks = Mocks{};

    var self = try init(mocks);
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
    const MockStateNixStartBuildLoop = struct {
        allocator: std.mem.Allocator,
        flake_url: []const u8,
        plugin_name: []const u8,
        callback: components.Nix.Callback,

        const info = @typeInfo(std.meta.Child(std.meta.fieldInfo(Mocks, .nix).type.MockStartBuildLoop).Fn).Fn;

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
    var mock_state_nix_start_build_loop: MockStateNixStartBuildLoop = undefined;
    defer {
        var ctx = &mock_state_nix_start_build_loop;
        ctx.allocator.free(ctx.flake_url);
        ctx.callback.deinit(ctx.allocator);
    }

    var mocks = Mocks{};
    mocks.nix.start_build_loop = meta.closure(MockStateNixStartBuildLoop.call, &mock_state_nix_start_build_loop);

    var self = try init(mocks);
    defer self.deinit();

    try self.expectEqualStdio("",
        \\cizero.nix_build("pdk_test_nix_build_callback", null, "
    ++ @TypeOf(mocks.nix).lock_flake_url_input ++
        \\")
        \\
    , {}, struct {
        fn call(_: void, rt: Plugin.Runtime) anyerror!void {
            try testing.expect(try rt.call("pdk_test_nix_build", &.{}, &.{}));
        }
    }.call);

    try testing.expectEqualStrings("pdk_test_nix_build_callback", mock_state_nix_start_build_loop.callback.func_name);
    try testing.expect(mock_state_nix_start_build_loop.callback.user_data == null);
    try testing.expectEqualStrings(@TypeOf(mocks.nix).lock_flake_url_output, mock_state_nix_start_build_loop.flake_url);

    const store_drv_output = "/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-example";
    const store_drv = store_drv_output ++ ".drv";

    try self.expectEqualStdio("",
        \\pdk_test_nix_build_callback(null, 0, "
    ++ @TypeOf(mocks.nix).lock_flake_url_output ++
        \\", "
    ++ store_drv ++
        \\", {
    ++ " " ++ store_drv_output ++
        \\ }, null)
        \\
    , &mock_state_nix_start_build_loop.callback, struct {
        fn call(cb: *const components.Nix.Callback, rt: Plugin.Runtime) anyerror!void {
            const linear = try rt.linearMemoryAllocator();
            const allocator = linear.allocator();

            const flake_url_wasm = try allocator.dupeZ(u8, std.meta.fieldInfo(Mocks, .nix).type.lock_flake_url_output);
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
