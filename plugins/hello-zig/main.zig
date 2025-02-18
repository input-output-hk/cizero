const builtin = @import("builtin");
const std = @import("std");

const cizero = @import("cizero");

pub const utils_nix_options = cizero.utils_nix_options;

const allocator = std.heap.wasm_allocator;

usingnamespace if (builtin.is_test) struct {} else struct {
    pub export fn pdk_test_timeout_on_timestamp() void {
        pdk_tests.@"timeout.onTimestamp"() catch |err| @panic(@errorName(err));
    }

    pub export fn pdk_test_timeout_on_cron() void {
        pdk_tests.@"timeout.onCron"() catch |err| @panic(@errorName(err));
    }

    pub export fn pdk_test_process_exec() void {
        pdk_tests.@"process.exec"() catch |err| @panic(@errorName(err));
    }

    pub export fn pdk_test_http_on_webhook() void {
        pdk_tests.@"http.onWebhook"() catch |err| @panic(@errorName(err));
    }

    pub export fn pdk_test_nix_on_build() void {
        pdk_tests.@"nix.onBuild"() catch |err| @panic(@errorName(err));
    }

    pub export fn pdk_test_nix_on_eval() void {
        pdk_tests.@"nix.onEval"() catch |err| @panic(@errorName(err));
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

        std.debug.print("{d}\n{d}\n", .{ now_ms, timestamp });
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
        std.debug.print("{s}\n{s}\n{d}\n", .{ cron, cron, result });
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
            std.debug.print("{}\n", .{err});
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
                    .status = .ok,
                    .body = "response body",
                };
            }
        }.callback;

        const user_data = Foo{
            .a = 25,
            .b = 372,
        };

        std.debug.print("{}\n", .{user_data});
        try cizero.http.onWebhook(UserData, allocator, callback, user_data);
    }

    pub fn @"nix.onBuild"() !void {
        const UserData = cizero.user_data.Shallow(void);

        const callback = struct {
            fn callback(
                _: UserData,
                build_result: cizero.nix.OnBuildResult,
            ) void {
                switch (build_result) {
                    .err => |name| std.debug.print("error.{s}\n", .{name}),
                    .ok => |payload| std.debug.print("{}\n{?s}\n{?s}\n{?s}\n", .{
                        {},
                        switch (payload) {
                            .outputs => |outputs| outputs,
                            else => null,
                        },
                        switch (payload) {
                            .failed => |failed| failed.builds,
                            else => null,
                        },
                        switch (payload) {
                            .failed => |failed| failed.dependents,
                            else => null,
                        },
                    }),
                }
            }
        }.callback;

        const installable = "/nix/store/g2mxdrkwr1hck4y5479dww7m56d1x81v-hello-2.12.1.drv^*";

        std.debug.print("{}\n{s}\n", .{ {}, [_][]const u8{installable} });
        try cizero.nix.onBuild(UserData, allocator, callback, {}, &.{installable});
    }

    pub fn @"nix.onEval"() !void {
        const UserData = cizero.user_data.Shallow(void);

        const callback = struct {
            fn callback(
                _: UserData,
                eval_result: cizero.nix.OnEvalResult,
            ) void {
                switch (eval_result) {
                    .err => |name| std.debug.print("error.{s}\n", .{name}),
                    .ok => |payload| std.debug.print("{}\n{?s}\n{?s}\n{?s}\n{?s}\n", .{
                        {},
                        switch (payload) {
                            .ok => |result| result,
                            else => null,
                        },
                        switch (payload) {
                            .failed => |err_msg| err_msg,
                            else => null,
                        },
                        switch (payload) {
                            .ifd_failed => |ifd_failed| ifd_failed.builds,
                            else => null,
                        },
                        switch (payload) {
                            .ifd_failed => |ifd_failed| ifd_failed.dependents,
                            else => null,
                        },
                    }),
                }
            }
        }.callback;

        const flake = "github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e";
        const expr = "flake: flake.legacyPackages.x86_64-linux.hello.meta.description";
        const format = cizero.nix.EvalFormat.raw;

        std.debug.print("{}\n{s}\n{s}\n{s}\n", .{ {}, flake, expr, @tagName(format) });
        try cizero.nix.onEval(UserData, allocator, callback, {}, flake, expr, format);
    }
};

/// Tests for further things provided by the PDK,
/// possibly built on top of cizero's host functions.
const tests = struct {
    pub fn @"nix.lockFlakeRef"() !void {
        const flake_locked = flake_locked: {
            var diagnostics: cizero.nix.FlakeMetadataDiagnostics = undefined;
            errdefer |err| switch (err) {
                error.FlakeMetadataFailed => {
                    defer diagnostics.FlakeMetadataFailed.deinit(allocator);
                    std.log.err("term: {}\nstderr: {s}", .{
                        diagnostics.FlakeMetadataFailed.term,
                        diagnostics.FlakeMetadataFailed.stderr,
                    });
                },
                else => {},
            };
            break :flake_locked try cizero.nix.lockFlakeRef(allocator, "github:NixOS/nixpkgs/23.11", .{}, &diagnostics);
        };
        defer allocator.free(flake_locked);

        try std.testing.expectEqualStrings("github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e", flake_locked);
    }

    pub fn @"nix.onEvalBuild"() !void {
        const UserData = cizero.user_data.S2S(?[]const u8);

        const fns = struct {
            fn evalCallback(user_data: UserData, arena_allocator: std.mem.Allocator, result: cizero.nix.OnEvalResult) UserData.Value {
                var drv = user_data.deserializeAlloc(arena_allocator) catch |err| @panic(@errorName(err));
                defer UserData.free(allocator, &drv);

                std.testing.expect(drv == null) catch |err| @panic(@errorName(err));

                return if (result == .ok and result.ok == .ok) result.ok.ok else null;
            }

            fn buildCallback(user_data: UserData, result: cizero.nix.OnBuildResult) void {
                var drv = user_data.deserializeAlloc(allocator) catch |err| @panic(@errorName(err));
                defer UserData.free(allocator, &drv);

                std.testing.expectEqual(std.meta.Tag(cizero.nix.OnBuildResult).ok, std.meta.activeTag(result)) catch |err| @panic(@errorName(err));
                const build_result = result.ok;

                std.testing.expectEqualStrings(drv.?, "/nix/store/g2mxdrkwr1hck4y5479dww7m56d1x81v-hello-2.12.1.drv") catch |err| @panic(@errorName(err));

                std.testing.expectEqual(std.meta.Tag(cizero.nix.OnBuildResult.Ok).outputs, std.meta.activeTag(build_result)) catch |err| @panic(@errorName(err));
                std.testing.expectEqual(1, build_result.outputs.len) catch |err| @panic(@errorName(err));
                std.testing.expectEqualStrings("/nix/store/sbldylj3clbkc0aqvjjzfa6slp4zdvlj-hello-2.12.1", build_result.outputs[0]) catch |err| @panic(@errorName(err));
            }
        };

        try cizero.nix.onEvalBuild(
            UserData,
            allocator,
            fns.evalCallback,
            fns.buildCallback,
            null,
            "github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e",
            "flake: flake.legacyPackages.x86_64-linux.hello.drvPath",
        );
    }
};

fn runContainerFns(comptime container: type) !void {
    inline for (@typeInfo(container).Struct.decls) |decl| {
        const func = @field(container, decl.name);
        const result = func();
        if (@typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?) == .ErrorUnion) try result;
    }
}

fn isPdkTest() bool {
    return std.process.hasEnvVar(allocator, "CIZERO_PDK_TEST") catch |err| @panic(@errorName(err));
}

pub fn main() u8 {
    if (!isPdkTest()) {
        runContainerFns(pdk_tests) catch |err| @panic(@errorName(err));
        runContainerFns(tests) catch |err| @panic(@errorName(err));
    }
    return 0;
}
