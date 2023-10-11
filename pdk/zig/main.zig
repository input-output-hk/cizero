const std = @import("std");

const externs = struct {
    // process
    extern "cizero" fn exec([*]const [*]const u8, usize, bool, ?[*]usize, usize, usize, [*]u8, *usize, *usize, *u8, *usize) u8;

    // timeout
    extern "cizero" fn onCron([*]const u8, [*]const u8) i64;
    extern "cizero" fn onTimestamp([*]const u8, i64) void;

    // to_upper
    extern "cizero" fn toUpper([*]u8) void;
};

pub fn exec(args: struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_map: ?*const std.process.EnvMap = null,
    max_output_bytes: usize = 50 * 1024,
    expand_arg0: std.process.Child.Arg0Expand = .no_expand,
}) std.process.Child.ExecError!std.process.Child.ExecResult {
    const argv = try args.allocator.alloc([:0]const u8, args.argv.len);
    defer args.allocator.free(argv);
    for (argv, args.argv) |*arg, args_arg| arg.* = try args.allocator.dupeZ(u8, args_arg);
    defer for (argv) |arg| args.allocator.free(arg);
    const argv_z = try args.allocator.alloc([*]const u8, argv.len);
    defer args.allocator.free(argv_z);
    for (argv_z, argv) |*arg_c, arg| arg_c.* = arg.ptr;

    const env_array = if (args.env_map) |env_map| blk: {
        const array = try args.allocator.alloc([:0]const u8, env_map.count() * 2);

        var env_iter = env_map.iterator();
        var i: usize = 0;
        while (env_iter.next()) |entry| {
            defer i += 2;
            array[i] = try args.allocator.dupeZ(u8, entry.key_ptr.*);
            array[i + 1] = try args.allocator.dupeZ(u8, entry.value_ptr.*);
        }

        break :blk array;
    } else null;
    defer if (env_array) |a| {
        for (a) |kv| args.allocator.free(kv);
        args.allocator.free(a);
    };
    const env_array_z = if (env_array) |a| try args.allocator.alloc([*]const u8, a.len) else null;
    defer if (env_array_z) |a| args.allocator.free(a);
    if (env_array_z) |a_z| {
        for (a_z, env_array.?) |*env_kv_z, env_kv| env_kv_z.* = env_kv.ptr;
    }

    var output = try args.allocator.alloc(u8, args.max_output_bytes);
    errdefer args.allocator.free(output);

    var stdout_len: usize = undefined;
    var stderr_len: usize = undefined;

    var term_tag: enum(u8) {
        Exited,
        Signal,
        Stopped,
        Unknown,
    } = undefined;
    var term_code: usize = undefined;

    const err_code = externs.exec(
        @ptrCast(argv_z.ptr),
        argv_z.len,
        args.expand_arg0 == .expand,
        if (env_array_z) |a| @ptrCast(a.ptr) else null,
        if (env_array_z) |a| a.len else 0,
        args.max_output_bytes,
        output.ptr,
        &stdout_len,
        &stderr_len,
        @ptrCast(&term_tag),
        &term_code,
    );
    if (err_code != 0) {
        inline for (std.meta.tags(std.process.Child.ExecError), 1..) |err, i|
            if (err_code == i) return err;
        unreachable;
    }

    return .{
        .term = switch (term_tag) {
            .Exited => .{ .Exited = @intCast(term_code) },
            .Signal => .{ .Signal = term_code },
            .Stopped => .{ .Stopped = term_code },
            .Unknown => .{ .Unknown = term_code },
        },
        .stdout = output[0..stdout_len],
        .stderr = if (stderr_len != 0) output[stdout_len .. stdout_len + stderr_len] else output[0..0],
    };
}

pub fn onCron(callback_func_name: [:0]const u8, cron_expr: [:0]const u8) i64 {
    return externs.onCron(callback_func_name.ptr, cron_expr.ptr);
}

pub fn onTimestamp(callback_func_name: [:0]const u8, timestamp_ms: i64) void {
    externs.onTimestamp(callback_func_name.ptr, timestamp_ms);
}

pub fn toUpper(alloc: std.mem.Allocator, lower: []const u8) ![]const u8 {
    var buf = try alloc.dupeZ(u8, lower);
    externs.toUpper(buf.ptr);
    return buf;
}
