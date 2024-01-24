const std = @import("std");

const lib = @import("lib");

export fn cizero_mem_alloc(len: usize, ptr_align: u8) ?[*]u8 {
    return std.heap.wasm_allocator.rawAlloc(len, ptr_align, 0);
}

export fn cizero_mem_resize(buf: [*]u8, buf_len: usize, buf_align: u8, new_len: usize) bool {
    return std.heap.wasm_allocator.rawResize(buf[0..buf_len], buf_align, new_len, 0);
}

export fn cizero_mem_free(buf: [*]u8, buf_len: usize, buf_align: u8) void {
    std.heap.wasm_allocator.rawFree(buf[0..buf_len], buf_align, 0);
}

const externs = struct {
    // http
    extern "cizero" fn on_webhook(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
    ) void;

    // nix
    extern "cizero" fn nix_build(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
        flake_url: [*:0]const u8,
    ) void;

    // process
    extern "cizero" fn exec(
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

    // timeout
    extern "cizero" fn on_cron(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
        cron: [*:0]const u8,
    ) i64;
    extern "cizero" fn on_timestamp(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
        timestamp: i64,
    ) void;
};

pub fn onWebhook(callback_func_name: [:0]const u8, user_data: anytype) void {
    const user_data_bytes = fixZeroLenSlice(u8, lib.mem.anyAsBytesUnpad(user_data));
    externs.on_webhook(callback_func_name.ptr, user_data_bytes.ptr, user_data_bytes.len);
}

pub fn nixBuild(callback_func_name: [:0]const u8, user_data: anytype, flake_url: [:0]const u8) !void {
    const user_data_bytes = fixZeroLenSlice(u8, lib.mem.anyAsBytesUnpad(user_data));
    externs.nix_build(callback_func_name, user_data_bytes.ptr, user_data_bytes.len, flake_url);
}

pub fn exec(args: struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_map: ?*const std.process.EnvMap = null,
    max_output_bytes: usize = 50 * 1024,
    expand_arg0: std.process.Child.Arg0Expand = .no_expand,
}) std.process.Child.RunError!std.process.Child.RunResult {
    const argv = try CStringArray.initDupe(args.allocator, args.argv);
    defer argv.deinit();

    const env_map = if (args.env_map) |env_map| try CStringArray.initStringStringMap(args.allocator, env_map) else null;
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

    const err_code = externs.exec(
        fixZeroLenSlice([*:0]const u8, argv.c).ptr,
        fixZeroLenSlice([*:0]const u8, argv.c).len,
        args.expand_arg0 == .expand,
        if (env_map) |env| @ptrCast(fixZeroLenSlice([*:0]const u8, env.c).ptr) else null,
        if (env_map) |env| fixZeroLenSlice([*:0]const u8, env.c).len else 0,
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

pub fn onCron(callback_func_name: [:0]const u8, user_data: anytype, cron_expr: [:0]const u8) i64 {
    const user_data_bytes = fixZeroLenSlice(u8, lib.mem.anyAsBytesUnpad(user_data));
    return externs.on_cron(callback_func_name.ptr, user_data_bytes.ptr, user_data_bytes.len, cron_expr.ptr);
}

pub fn onTimestamp(callback_func_name: [:0]const u8, user_data: anytype, timestamp_ms: i64) void {
    const user_data_bytes = fixZeroLenSlice(u8, lib.mem.anyAsBytesUnpad(user_data));
    externs.on_timestamp(callback_func_name.ptr, user_data_bytes.ptr, user_data_bytes.len, timestamp_ms);
}

const CStringArray = struct {
    allocator: std.mem.Allocator,

    z: ?[]const [:0]const u8,
    c: []const [*:0]const u8,

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.c);

        if (self.z) |z| {
            for (z) |ze| self.allocator.free(ze);
            self.allocator.free(z);
        }
    }

    pub fn initDupe(allocator: std.mem.Allocator, array: []const []const u8) !@This() {
        const z = try allocator.alloc([:0]const u8, array.len);
        errdefer {
            for (z) |zz| allocator.free(zz);
            allocator.free(z);
        }
        for (z, array) |*ze, e| ze.* = try allocator.dupeZ(u8, e);

        var self = try initRef(allocator, z);
        self.z = z;

        return self;
    }

    pub fn initRef(allocator: std.mem.Allocator, z: []const [:0]const u8) !@This() {
        const c = try allocator.alloc([*:0]const u8, z.len);
        errdefer allocator.free(c);
        for (c, z) |*ce, ze| ce.* = ze.ptr;

        return .{ .allocator = allocator, .z = null, .c = c };
    }

    pub fn initStringStringMap(allocator: std.mem.Allocator, map: anytype) !@This() {
        const z = try allocator.alloc([:0]const u8, map.count() * 2);
        errdefer {
            for (z) |k_or_v| allocator.free(k_or_v);
            allocator.free(z);
        }

        var iter = map.iterator();
        var i: usize = 0;
        while (iter.next()) |kv| {
            defer i += 2;
            z[i] = try allocator.dupeZ(u8, kv.key_ptr.*);
            z[i + 1] = try allocator.dupeZ(u8, kv.value_ptr.*);
        }

        var self = try initRef(allocator, z);
        self.z = z;

        return self;
    }
};

// For some reason the pointer of a slice of a zero-length array
// becomes negative when received by cizero.
fn fixZeroLenSlice(comptime T: type, slice: []const T) []const T {
    return if (slice.len == 0)
        @as([1]T, undefined)[0..0]
    else
        slice;
}
