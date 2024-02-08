const builtin = @import("builtin");
const std = @import("std");

const cizero = @import("cizero");
const lib = @import("lib");

const root = @This();

const allocator = std.heap.wasm_allocator;

usingnamespace if (builtin.is_test) struct {} else struct {
    pub export fn pdk_test_on_timestamp() void {
        pdk_tests.onTimestamp();
    }

    export fn pdk_test_on_timestamp_callback(user_data: *const i64, user_data_len: usize) void {
        std.debug.assert(user_data_len == lib.mem.sizeOfUnpad(i64));
        std.debug.print("{s}({d})\n", .{ @src().fn_name, user_data.* });
    }

    pub export fn pdk_test_on_cron() void {
        pdk_tests.onCron();
    }

    export fn pdk_test_on_cron_callback(user_data_ptr: [*]const u8, user_data_len: usize) bool {
        std.debug.assert(user_data_len == "* * * * *".len);
        const user_data = user_data_ptr[0..user_data_len];

        std.debug.print("{s}(\"{s}\")\n", .{ @src().fn_name, user_data });
        return false;
    }

    pub export fn pdk_test_exec() void {
        tryFn(pdk_tests.exec, .{}, {});
    }

    pub export fn pdk_test_on_webhook() void {
        pdk_tests.onWebhook();
    }

    export fn pdk_test_on_webhook_callback(
        user_data: ?*const root.pdk_tests.OnWebhookUserData,
        user_data_len: usize,
        req_body_ptr: [*:0]const u8,
        res_status: *u16,
        res_body_ptr: *?[*:0]const u8,
    ) bool {
        std.debug.assert(user_data_len == lib.mem.sizeOfUnpad(root.pdk_tests.OnWebhookUserData));
        std.debug.assert(res_status.* == 204);

        const req_body = std.mem.span(req_body_ptr);

        std.debug.print("{s}(.{{ {d}, {d} }}, \"{s}\")\n", .{ @src().fn_name, user_data.?.a, user_data.?.b, req_body });

        res_status.* = 200;
        res_body_ptr.* = "response body";

        return false;
    }

    pub export fn pdk_test_nix_build() void {
        tryFn(pdk_tests.nixBuild, .{}, {});
    }

    export fn pdk_test_nix_build_callback(
        user_data: ?*const root.pdk_tests.OnWebhookUserData,
        user_data_len: usize,
        flake_url_locked: [*:0]const u8,
        store_drv: [*:0]const u8,
        outputs_ptr: [*]const [*:0]const u8,
        outputs_len: usize,
        failed_drv: ?[*:0]const u8,
    ) void {
        std.debug.assert(user_data == null);
        std.debug.assert(user_data_len == 0);
        std.debug.assert(failed_drv == null);

        std.debug.print("{s}(null, 0, \"{s}\", \"{s}\", {s}, {any})\n", .{
            @src().fn_name,
            flake_url_locked,
            store_drv,
            outputs_ptr[0..outputs_len],
            failed_drv,
        });
    }
};

const pdk_tests = struct {
    pub fn onTimestamp() void {
        const now_ms: i64 = if (isPdkTest()) std.time.ms_per_s else std.time.milliTimestamp();

        std.debug.print("cizero.on_timestamp(\"{s}\", {d}, {d})\n", .{ "pdk_test_on_timestamp_callback", now_ms, now_ms + 2 * std.time.ms_per_s });
        cizero.onTimestamp("pdk_test_on_timestamp_callback", &now_ms, now_ms + 2 * std.time.ms_per_s);
    }

    pub fn onCron() void {
        const cron = "* * * * *";
        const args = .{ "pdk_test_on_cron_callback", @as([]const u8, cron), cron };
        const result = @call(.auto, cizero.onCron, args);
        std.debug.print("cizero.on_cron(\"{s}\", \"{s}\", \"{s}\") {d}\n", args ++ .{result});
    }

    pub fn exec() !void {
        var env = std.process.EnvMap.init(allocator);
        try env.put("foo", "bar");
        defer env.deinit();

        const result = cizero.exec(.{
            .allocator = allocator,
            .argv = &.{
                "sh", "-c",
                \\echo     stdout
                \\echo >&2 stderr \$foo="$foo"
            },
            .env_map = &env,
        }) catch |err| {
            std.debug.print("cizero.{s}(…) {}\n", .{ @src().fn_name, err });
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

    const OnWebhookUserData = packed struct {
        a: u8,
        b: u16,
    };

    pub fn onWebhook() void {
        const user_data = OnWebhookUserData{
            .a = 25,
            .b = 372,
        };
        std.debug.print("cizero.on_webhook(\"{s}\", .{{ {d}, {d} }})\n", .{ "pdk_test_on_webhook_callback", user_data.a, user_data.b });
        cizero.onWebhook("pdk_test_on_webhook_callback", &user_data);
    }

    pub fn nixBuild() !void {
        const args = .{
            "pdk_test_nix_build_callback",
            null,
            "github:NixOS/nixpkgs/nixos-23.11#hello^out",
        };
        std.debug.print("cizero.nix_build(\"{s}\", {}, \"{s}\")\n", args);
        try @call(.auto, cizero.nixBuild, args);
    }
};

fn isPdkTest() bool {
    return std.process.hasEnvVar(allocator, "CIZERO_PDK_TEST") catch std.debug.panic("OOM", .{});
}

fn FnErrorUnionPayload(comptime Fn: type) type {
    return @typeInfo(@typeInfo(Fn).Fn.return_type.?).ErrorUnion.payload;
}

fn tryFn(func: anytype, args: anytype, default: FnErrorUnionPayload(@TypeOf(func))) FnErrorUnionPayload(@TypeOf(func)) {
    return @call(.auto, func, args) catch |err| {
        std.log.err("{}\n", .{err});
        return default;
    };
}

pub fn main() u8 {
    return tryFn(mainZig, .{}, 1);
}

fn mainZig() !u8 {
    if (!isPdkTest()) inline for (@typeInfo(pdk_tests).Struct.decls) |decl| {
        const func = @field(pdk_tests, decl.name);
        if (@typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?) == .ErrorUnion) {
            try func();
        } else func();
    };
    return 0;
}
