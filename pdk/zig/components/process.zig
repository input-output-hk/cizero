const std = @import("std");

const abi = @import("../abi.zig");

const externs = struct {
    extern "cizero" fn process_exec(
        argv_ptr: [*]const [*:0]const u8,
        argc: usize,
        expand_arg0: bool,
        env_map: ?[*]const usize,
        env_map_len: usize,
        max_output_bytes: usize,
        output_ptr: [*]u8,
        stdout_len: *usize,
        stderr_len: *usize,
        term_tag: *u8,
        term_code: *usize,
    ) u8;
};

pub fn exec(args: struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_map: ?*const std.process.EnvMap = null,
    max_output_bytes: usize = 50 * 1024,
    expand_arg0: std.process.Child.Arg0Expand = .no_expand,
}) std.process.Child.RunError!std.process.Child.RunResult {
    const argv = try abi.CStringArray.initDupe(args.allocator, args.argv);
    defer argv.deinit();

    const env_map = if (args.env_map) |env_map| try abi.CStringArray.initStringStringMap(args.allocator, env_map) else null;
    defer if (env_map) |env| env.deinit();

    var output = try args.allocator.alloc(u8, args.max_output_bytes);
    defer args.allocator.free(output);

    var stdout_len: usize = undefined;
    var stderr_len: usize = undefined;

    var term_tag: enum(u8) {
        Exited,
        Signal,
        Stopped,
        Unknown,
    } = undefined;
    var term_code: usize = undefined;

    const err_code = externs.process_exec(
        abi.fixZeroLenSlice([*:0]const u8, argv.c).ptr,
        abi.fixZeroLenSlice([*:0]const u8, argv.c).len,
        args.expand_arg0 == .expand,
        if (env_map) |env| @ptrCast(abi.fixZeroLenSlice([*:0]const u8, env.c).ptr) else null,
        if (env_map) |env| abi.fixZeroLenSlice([*:0]const u8, env.c).len else 0,
        args.max_output_bytes,
        output.ptr,
        &stdout_len,
        &stderr_len,
        @ptrCast(&term_tag),
        &term_code,
    );
    if (err_code != 0) {
        const E = std.process.Child.RunError;

        const err_tags = try args.allocator.dupe(E, std.meta.tags(E));
        defer args.allocator.free(err_tags);

        std.mem.sortUnstable(E, err_tags, {}, struct {
            fn call(_: void, lhs: E, rhs: E) bool {
                return std.mem.order(u8, @errorName(lhs), @errorName(rhs)) == .lt;
            }
        }.call);

        for (err_tags, 1..) |err, i|
            if (err_code == i) return err;
        unreachable;
    }

    const stdout = try args.allocator.dupe(u8, output[0..stdout_len]);
    errdefer args.allocator.free(stdout);

    const stderr = try args.allocator.dupe(u8, output[stdout_len .. stdout_len + stderr_len]);
    errdefer args.allocator.free(stderr);

    return .{
        .term = switch (term_tag) {
            .Exited => .{ .Exited = @intCast(term_code) },
            .Signal => .{ .Signal = term_code },
            .Stopped => .{ .Stopped = term_code },
            .Unknown => .{ .Unknown = term_code },
        },
        .stdout = stdout,
        .stderr = stderr,
    };
}
