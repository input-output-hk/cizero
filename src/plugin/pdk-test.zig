const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

const mem = @import("../mem.zig");
const meta = @import("../meta.zig");
const wasm = @import("../wasm.zig");

const Cizero = @import("../Cizero.zig");
const Plugin = @import("../Plugin.zig");

cizero: *Cizero,
plugin: Plugin,
wasi_config: Plugin.Runtime.WasiConfig,

const Mocks = struct {
    timeout: struct {
        milli_timestamp: meta.Closure(fn () i64, true) = meta.disclosure(struct {
            fn call() i64 {
                return std.time.ms_per_s;
            }
        }.call, true),
    } = .{},

    process: struct {
        exec: meta.Closure(@TypeOf(std.process.Child.exec), true) = meta.disclosure(struct {
            const info = @typeInfo(@TypeOf(std.process.Child.exec)).Fn;

            fn call(_: info.params[0].type.?) info.return_type.? {
                return error.Unexpected;
            }
        }.call, true),
    } = .{},
};

fn deinit(self: *@This()) void {
    self.wasi_config.env.?.env.deinit(testing.allocator);
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

    cizero.components.timeout.milli_timestamp_closure = mocks.timeout.milli_timestamp;
    cizero.components.process.exec_closure = mocks.process.exec;

    const plugin = .{ .path = build_options.plugin_path };
    _ = try cizero.registry.registerPlugin(plugin);

    return .{
        .cizero = cizero,
        .plugin = plugin,
        .wasi_config = cizero.registry.wasi_config,
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

    var wasi_config = self.wasi_config;
    const collect_output = try wasi_config.collectOutput(testing.allocator);
    defer collect_output.deinit();
    try rt.configureWasi(wasi_config);

    try run_fn(run_fn_ctx, rt);

    const output = try collect_output.collect(std.math.maxInt(usize));
    defer output.deinit();

    try testing.expectEqualStrings(stdout, output.stdout);
    try testing.expectEqualStrings(stderr, output.stderr);
}

test "onTimestamp" {
    const mocks = Mocks{};

    var self = try init(mocks);
    defer self.deinit();

    try self.expectEqualStdio("",
        \\cizero.onTimestamp("pdk_test_on_timestamp_callback", 1000, 3000)
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

test "onCron" {
    const mocks = Mocks{};

    var self = try init(mocks);
    defer self.deinit();

    try self.expectEqualStdio("",
        \\cizero.onCron("pdk_test_on_cron_callback", 1000, "* * * * *") 60000
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

    {
        const user_data: [@sizeOf(i64)]u8 = @bitCast(mocks.timeout.milli_timestamp.call(.{}));

        try testing.expectEqualStrings("pdk_test_on_cron_callback", callback.func_name);
        try testing.expect(callback.user_data != null);
        try testing.expectEqualSlices(u8, &user_data, callback.user_data.?);
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
    }

    try self.expectEqualStdio("",
        \\pdk_test_on_cron_callback(1000)
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

                try testing.expectEqual(args.max_output_bytes, 50 * 1024);

                try testing.expectEqual(args.expand_arg0, .no_expand);
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

test "onWebhook" {
    const mocks = Mocks{};

    var self = try init(mocks);
    defer self.deinit();

    try self.expectEqualStdio("",
        \\cizero.onWebhook("pdk_test_on_webhook_callback", .{ 25, 372 })
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

    {
        const UserData = packed struct {
            a: u8,
            b: u16,
        };

        const user_data: [mem.sizeOfUnpad(UserData)]u8 = @bitCast(UserData{
            .a = 25,
            .b = 372,
        });

        try testing.expectEqualStrings("pdk_test_on_webhook_callback", callback.func_name);
        try testing.expect(callback.user_data != null);
        try testing.expectEqualSlices(u8, &user_data, callback.user_data.?);
        try testing.expectEqualDeep(Callback.Condition.webhook, callback.condition);
    }

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
