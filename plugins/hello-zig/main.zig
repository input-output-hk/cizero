const builtin = @import("builtin");
const std = @import("std");

const cizero = @import("cizero");
const lib = @import("lib");

const root = @This();

const allocator = std.heap.wasm_allocator;

usingnamespace if (builtin.is_test) struct {} else struct {
    pub export fn pdk_test_timeout_on_timestamp() void {
        pdk_tests.@"timeout.onTimestamp"();
    }

    export fn pdk_test_timeout_on_timestamp_callback(user_data: *const i64, user_data_len: usize) void {
        std.debug.assert(user_data_len == lib.mem.sizeOfUnpad(i64));
        std.debug.print("{s}\n{d}\n", .{ @src().fn_name, user_data.* });
    }

    pub export fn pdk_test_timeout_on_cron() void {
        pdk_tests.@"timeout.onCron"();
    }

    export fn pdk_test_timeout_on_cron_callback(user_data_ptr: [*]const u8, user_data_len: usize) bool {
        std.debug.assert(user_data_len == "* * * * *".len);
        const user_data = user_data_ptr[0..user_data_len];

        std.debug.print("{s}\n{s}\n", .{ @src().fn_name, user_data });
        return false;
    }

    pub export fn pdk_test_process_exec() void {
        tryFn(pdk_tests.@"process.exec", .{}, {});
    }

    pub export fn pdk_test_http_on_webhook() void {
        pdk_tests.@"http.onWebhook"();
    }

    export fn pdk_test_http_on_webhook_callback(
        user_data: ?*const root.pdk_tests.HttpOnWebhookUserData,
        user_data_len: usize,
        req_body_ptr: [*:0]const u8,
        res_status: *u16,
        res_body_ptr: *?[*:0]const u8,
    ) bool {
        std.debug.assert(user_data_len == lib.mem.sizeOfUnpad(root.pdk_tests.HttpOnWebhookUserData));
        std.debug.assert(res_status.* == 204);

        const req_body = std.mem.span(req_body_ptr);

        std.debug.print("{s}\n.{{ {d}, {d} }}\n{s}\n", .{ @src().fn_name, user_data.?.a, user_data.?.b, req_body });

        res_status.* = 200;
        res_body_ptr.* = "response body";

        return false;
    }

    pub export fn pdk_test_nix_on_build() void {
        tryFn(pdk_tests.@"nix.onBuild", .{}, {});
    }

    export fn pdk_test_nix_on_build_callback(
        user_data: ?*const anyopaque,
        user_data_len: usize,
        outputs_ptr: [*]const [*:0]const u8,
        outputs_len: usize,
        failed_dep: ?[*:0]const u8,
    ) void {
        std.debug.assert(user_data == null);
        std.debug.assert(user_data_len == 0);

        std.debug.print("{s}\nnull\n0\n{s}\n{?s}\n", .{
            @src().fn_name,
            outputs_ptr[0..outputs_len],
            failed_dep,
        });
    }

    pub export fn pdk_test_nix_on_eval() void {
        tryFn(pdk_tests.@"nix.onEval", .{}, {});
    }

    export fn pdk_test_nix_on_eval_callback(
        user_data: ?*const anyopaque,
        user_data_len: usize,
        result: ?[*:0]const u8,
        err_msg: ?[*:0]const u8,
        failed_ifd: ?[*:0]const u8,
        failed_ifd_dep: ?[*:0]const u8,
    ) void {
        std.debug.assert(user_data == null);
        std.debug.assert(user_data_len == 0);

        std.debug.print("{s}\nnull\n0\n{?s}\n{?s}\n{?s}\n{?s}\n", .{
            @src().fn_name,
            result,
            err_msg,
            failed_ifd,
            failed_ifd_dep,
        });
    }
};

/// Tests for cizero's host functions.
/// These are invoked by the PDK tests
/// to test communication over the ABI.
const pdk_tests = struct {
    pub fn @"timeout.onTimestamp"() void {
        const now_ms: i64 = if (isPdkTest()) std.time.ms_per_s else std.time.milliTimestamp();

        std.debug.print("cizero.timeout_on_timestamp\n{s}\n{d}\n{d}\n", .{ "pdk_test_timeout_on_timestamp_callback", now_ms, now_ms + 2 * std.time.ms_per_s });
        cizero.timeout.onTimestamp("pdk_test_timeout_on_timestamp_callback", &now_ms, now_ms + 2 * std.time.ms_per_s);
    }

    pub fn @"timeout.onCron"() void {
        const cron = "* * * * *";
        const args = .{ "pdk_test_timeout_on_cron_callback", @as([]const u8, cron), cron };
        const result = @call(.auto, cizero.timeout.onCron, args);
        std.debug.print("cizero.timeout_on_cron\n{s}\n{s}\n{s}\n{d}\n", args ++ .{result});
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

    const HttpOnWebhookUserData = packed struct {
        a: u8,
        b: u16,
    };

    pub fn @"http.onWebhook"() void {
        const user_data = HttpOnWebhookUserData{
            .a = 25,
            .b = 372,
        };
        std.debug.print("cizero.http_on_webhook\n{s}\n.{{ {d}, {d} }}\n", .{ "pdk_test_http_on_webhook_callback", user_data.a, user_data.b });
        cizero.http.onWebhook("pdk_test_http_on_webhook_callback", &user_data);
    }

    pub fn @"nix.onBuild"() !void {
        const args = .{
            "pdk_test_nix_on_build_callback",
            null,
            "/nix/store/g2mxdrkwr1hck4y5479dww7m56d1x81v-hello-2.12.1.drv^*",
        };
        std.debug.print("cizero.nix_on_build\n{s}\n{}\n{s}\n", args);
        try @call(.auto, cizero.nix.onBuild, args);
    }

    pub fn @"nix.onEval"() !void {
        const args = .{
            "pdk_test_nix_on_eval_callback",
            null,
            "(builtins.getFlake github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e).legacyPackages.x86_64-linux.hello.meta.description",
            .raw,
        };
        std.debug.print("cizero.nix_on_eval\n{s}\n{}\n{s}\n{}\n", args);
        try @call(.auto, cizero.nix.onEval, args);
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
