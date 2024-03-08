const builtin = @import("builtin");
const std = @import("std");

const cizero = @import("cizero");
const lib = @import("lib");

const root = @This();

const allocator = std.heap.wasm_allocator;

usingnamespace if (builtin.is_test) struct {} else struct {
    pub export fn pdk_test_timeout_on_timestamp() void {
        tryFn(pdk_tests.@"timeout.onTimestamp", .{}, {});
    }

    pub export fn pdk_test_timeout_on_cron() void {
        tryFn(pdk_tests.@"timeout.onCron", .{}, {});
    }

    pub export fn pdk_test_process_exec() void {
        tryFn(pdk_tests.@"process.exec", .{}, {});
    }

    pub export fn pdk_test_http_on_webhook() void {
        tryFn(pdk_tests.@"http.onWebhook", .{}, {});
    }

    pub export fn pdk_test_nix_on_build() void {
        tryFn(pdk_tests.@"nix.onBuild", .{}, {});
    }

    pub export fn pdk_test_nix_on_eval() void {
        tryFn(pdk_tests.@"nix.onEval", .{}, {});
    }
};

/// Tests for cizero's host functions.
/// These are invoked by the PDK tests
/// to test communication over the ABI.
const pdk_tests = struct {
    pub fn @"timeout.onTimestamp"() !void {
        const UserData = cizero.user_data.S2S(i64);

        const callback = struct {
            fn callback(user_data: UserData) void {
                const scheduled_ms = user_data.deserialize() catch |err| @panic(@errorName(err));

                std.debug.print("{d}\n", .{scheduled_ms});
            }
        }.callback;

        const now_ms: i64 = if (isPdkTest()) std.time.ms_per_s else std.time.milliTimestamp();
        const timestamp = now_ms + 2 * std.time.ms_per_s;

        // XXX do not print cizero.timeout_on_timestamp etc in PDK tests
        std.debug.print("cizero.timeout_on_timestamp\n{d}\n{d}\n", .{ now_ms, timestamp });
        try cizero.timeout.onTimestamp(UserData, allocator, callback, now_ms, timestamp);
    }

    pub fn @"timeout.onCron"() !void {
        const UserData = cizero.user_data.S2S([]const u8);

        const cron = "* * * * *";

        const callback = struct {
            fn callback(user_data: UserData) bool {
                var ud_cron = user_data.deserializeAlloc(allocator) catch |err| @panic(@errorName(err));
                defer UserData.free(allocator, &ud_cron);

                std.debug.assert(std.mem.eql(u8, ud_cron, cron));

                std.debug.print("{s}\n", .{ud_cron});
                return false;
            }
        }.callback;

        const result = try cizero.timeout.onCron(UserData, allocator, callback, cron, cron);
        std.debug.print("cizero.timeout_on_cron\n{s}\n{s}\n{d}\n", .{ cron, cron, result });
    }

    pub fn @"process.exec"() !void {
        var env = std.process.EnvMap.init(allocator);
        try env.put("foo", "bar");
        defer env.deinit();

        const result = cizero.process.exec(.{
            .allocator = allocator,
            .argv = &.{
                "sh", "-c",
                \\echo     stdout
                \\echo >&2 stderr \$foo="$foo"
            },
            .env_map = &env,
        }) catch |err| {
            std.debug.print("cizero.{s}\n{}\n", .{ @src().fn_name, err });
            return err;
        };
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        std.debug.print(
            \\term tag: {s}
            \\term code: {d}
            \\stdout: {s}
            \\stderr: {s}
            \\
        , .{ @tagName(result.term), switch (result.term) {
            .Exited => |code| code,
            .Signal, .Stopped, .Unknown => |code| code,
        }, result.stdout, result.stderr });
    }

    pub fn @"http.onWebhook"() !void {
        const Foo = packed struct {
            a: u8,
            b: u16,

            pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                try writer.print(".{{ {d}, {d} }}", .{ self.a, self.b });
            }
        };

        const UserData = cizero.user_data.Shallow(Foo);

        const callback = struct {
            fn callback(
                user_data: UserData,
                body: []const u8,
            ) cizero.http.OnWebhookCallbackResponse {
                const foo = user_data.deserialize();

                std.debug.print("{}\n{s}\n", .{ foo, body });

                return .{
                    .status = 200,
                    .body = "response body",
                };
            }
        }.callback;

        const user_data = Foo{
            .a = 25,
            .b = 372,
        };

        std.debug.print("cizero.http_on_webhook\n{}\n", .{user_data});
        try cizero.http.onWebhook(UserData, allocator, callback, user_data);
    }

    pub fn @"nix.onBuild"() !void {
        const UserData = cizero.user_data.Shallow(void);

        const callback = struct {
            fn callback(
                _: UserData,
                build_result: cizero.nix.OnBuildResult,
            ) void {
                std.debug.print("{}\n{s}\n{s}\n", .{
                    {},
                    switch (build_result) {
                        .outputs => |outputs| outputs,
                        else => &[_][]const u8{},
                    },
                    switch (build_result) {
                        .deps_failed => |deps_failed| deps_failed,
                        else => &[_][]const u8{},
                    },
                });
            }
        }.callback;

        const installable = "/nix/store/g2mxdrkwr1hck4y5479dww7m56d1x81v-hello-2.12.1.drv^*";

        std.debug.print("cizero.nix_on_build\n{}\n{s}\n", .{ {}, installable });
        try cizero.nix.onBuild(UserData, allocator, callback, {}, installable);
    }

    pub fn @"nix.onEval"() !void {
        const UserData = cizero.user_data.Shallow(void);

        const callback = struct {
            fn callback(
                _: UserData,
                eval_result: cizero.nix.OnEvalResult,
            ) void {
                std.debug.print("{}\n{?s}\n{?s}\n{?s}\n{s}\n", .{
                    {},
                    switch (eval_result) {
                        .ok => |result| result,
                        else => null,
                    },
                    switch (eval_result) {
                        .failed => |err_msg| err_msg,
                        else => null,
                    },
                    switch (eval_result) {
                        .ifd_failed => |drv| drv,
                        .ifd_deps_failed => |ifd_deps_failed| ifd_deps_failed.ifd,
                        else => null,
                    },
                    switch (eval_result) {
                        .ifd_deps_failed => |ifd_deps_failed| ifd_deps_failed.drvs,
                        else => &[_][]const u8{},
                    },
                });
            }
        }.callback;

        const expr = "(builtins.getFlake github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e).legacyPackages.x86_64-linux.hello.meta.description";
        const format = cizero.nix.EvalFormat.raw;

        std.debug.print("cizero.nix_on_eval\n{}\n{s}\n{s}\n", .{ {}, expr, @tagName(format) });
        try cizero.nix.onEval(UserData, allocator, callback, {}, expr, format);
    }
};

/// Tests for further things provided by the PDK,
/// possibly built on top of cizero's host functions.
const tests = struct {
    pub fn @"nix.lockFlakeRef"() !void {
        const flake_locked = try cizero.nix.lockFlakeRef(allocator, "github:NixOS/nixpkgs/23.11", .{});
        defer allocator.free(flake_locked);

        try std.testing.expectEqualStrings("github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e", flake_locked);
    }

    pub fn @"nix.onEvalBuild"() !void {
        const UserData = cizero.user_data.S2S(?[]const u8);

        const fns = struct {
            fn evalCallback(user_data: UserData, _: std.mem.Allocator, result: cizero.nix.OnEvalResult) UserData.Value {
                var drv = user_data.deserializeAlloc(allocator) catch |err| @panic(@errorName(err));
                defer UserData.free(allocator, &drv);

                return if (result == .ok) result.ok else drv;
            }

            fn buildCallback(user_data: UserData, result: cizero.nix.OnBuildResult) void {
                var drv = user_data.deserializeAlloc(allocator) catch |err| @panic(@errorName(err));
                defer UserData.free(allocator, &drv);

                std.testing.expectEqualStrings(drv.?, "/nix/store/g2mxdrkwr1hck4y5479dww7m56d1x81v-hello-2.12.1.drv") catch |err| @panic(@errorName(err));

                std.testing.expectEqual(std.meta.Tag(cizero.nix.OnBuildResult).outputs, std.meta.activeTag(result)) catch |err| @panic(@errorName(err));
                std.testing.expectEqual(1, result.outputs.len) catch |err| @panic(@errorName(err));
                std.testing.expectEqualStrings("/nix/store/sbldylj3clbkc0aqvjjzfa6slp4zdvlj-hello-2.12.1", result.outputs[0]) catch |err| @panic(@errorName(err));
            }
        };

        try cizero.nix.onEvalBuild(
            UserData,
            allocator,
            fns.evalCallback,
            fns.buildCallback,
            null,
            "(builtins.getFlake github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e).legacyPackages.x86_64-linux.hello.drvPath",
        );
    }
};

fn FnErrorUnionPayload(comptime Fn: type) type {
    return @typeInfo(@typeInfo(Fn).Fn.return_type.?).ErrorUnion.payload;
}

fn tryFn(func: anytype, args: anytype, default: FnErrorUnionPayload(@TypeOf(func))) FnErrorUnionPayload(@TypeOf(func)) {
    return @call(.auto, func, args) catch |err| {
        std.log.err("{}\n", .{err});
        return default;
    };
}

fn runContainerFns(comptime container: type) !void {
    inline for (@typeInfo(container).Struct.decls) |decl| {
        const func = @field(container, decl.name);
        const result = func();
        if (@typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?) == .ErrorUnion) try result;
    }
}

fn isPdkTest() bool {
    return std.process.hasEnvVar(allocator, "CIZERO_PDK_TEST") catch std.debug.panic("OOM", .{});
}

pub fn main() u8 {
    return tryFn(mainZig, .{}, 1);
}

fn mainZig() !u8 {
    if (!isPdkTest()) {
        try runContainerFns(pdk_tests);
        try runContainerFns(tests);
    }
    return 0;
}
