const builtin = @import("builtin");
const std = @import("std");
const cizero = @import("cizero");

const root = @This();

const allocator = std.heap.wasm_allocator;

usingnamespace if (builtin.is_test) struct {} else struct {
    pub export fn toUpper() void {
        tryFn(pdk_tests.toUpper, .{}, {});
    }

    pub export fn onTimestamp() void {
        pdk_tests.onTimestamp();
    }

    export fn onTimestampCallback(user_data: *const i64, user_data_len: usize) void {
        std.debug.assert(user_data_len == @sizeOf(i64));
        std.debug.print("{s}({d})\n", .{ @src().fn_name, user_data.* });
    }

    pub export fn onCron() void {
        pdk_tests.onCron();
    }

    export fn onCronCallback(user_data: *const i64, user_data_len: usize) bool {
        std.debug.assert(user_data_len == @sizeOf(i64));
        std.debug.print("{s}({d})\n", .{ @src().fn_name, user_data.* });
        return false;
    }

    pub export fn exec() void {
        tryFn(pdk_tests.exec, .{}, {});
    }

    pub export fn onWebhook() void {
        pdk_tests.onWebhook();
    }

    export fn onWebhookCallback(user_data: ?*const root.pdk_tests.OnWebhookUserData, user_data_len: usize, body_ptr: [*:0]const u8) bool {
        std.debug.assert(user_data_len == cizero.sizeOfUnpad(root.pdk_tests.OnWebhookUserData));

        const body = std.mem.span(body_ptr);

        std.debug.print("{s}(.{{ {d}, {d} }}, \"{s}\")\n", .{ @src().fn_name, user_data.?.a, user_data.?.b, body });

        return false;
    }
};

const pdk_tests = struct {
    pub fn toUpper() !void {
        inline for (.{ "foo", "bar" }) |arg| {
            const upper = try cizero.toUpper(allocator, arg);
            defer allocator.free(upper);

            std.debug.print("cizero.{s}({s}) {s}\n", .{ @src().fn_name, arg, upper });
        }
    }

    pub fn onTimestamp() void {
        const now_ms: i64 = if (isPdkTest()) std.time.ms_per_s else std.time.milliTimestamp();

        std.debug.print("cizero.{s}(\"{s}\", {d}, {d})\n", .{ @src().fn_name, "onTimestampCallback", now_ms, now_ms + 2 * std.time.ms_per_s });
        cizero.onTimestamp("onTimestampCallback", &now_ms, now_ms + 2 * std.time.ms_per_s);
    }

    pub fn onCron() void {
        const now_ms: i64 = if (isPdkTest()) std.time.ms_per_s else std.time.milliTimestamp();

        const result = cizero.onCron("onCronCallback", &now_ms, "* * * * *");
        std.debug.print("cizero.{s}(\"{s}\", {d}, \"{s}\") {d}\n", .{ @src().fn_name, "onCronCallback", now_ms, "* * * * *" } ++ .{result});
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
        std.debug.print("cizero.{s}(\"{s}\", .{{ {d}, {d} }})\n", .{ @src().fn_name, "onWebhookCallback", user_data.a, user_data.b });
        cizero.onWebhook("onWebhookCallback", &user_data);
    }
};

fn isPdkTest() bool {
    return std.process.hasEnvVar(allocator, "CIZERO_PDK_TEST") catch @panic("OOM");
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
