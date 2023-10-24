const std = @import("std");

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
    extern "cizero" fn onWebhook([*]const u8) void;

    // process
    extern "cizero" fn exec([*]const [*]const u8, usize, bool, ?[*]const usize, usize, usize, [*]u8, *usize, *usize, *u8, *usize) u8;

    // timeout
    extern "cizero" fn onCron([*]const u8, [*]const u8) i64;
    extern "cizero" fn onTimestamp([*]const u8, i64) void;

    // to_upper
    extern "cizero" fn toUpper([*]u8) void;
};

pub fn onWebhook(callback_func_name: [:0]const u8) void {
    externs.onWebhook(callback_func_name.ptr);
}

pub fn exec(args: struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_map: ?*const std.process.EnvMap = null,
    max_output_bytes: usize = 50 * 1024,
    expand_arg0: std.process.Child.Arg0Expand = .no_expand,
}) std.process.Child.ExecError!std.process.Child.ExecResult {
    const argv = try CStringArray.initDupe(args.allocator, args.argv);
    defer argv.deinit();

    const env_map = if (args.env_map) |env_map| try CStringArray.initStringStringMap(args.allocator, env_map) else null;
    defer if (env_map) |env| env.deinit();

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
        @ptrCast(argv.c.ptr),
        argv.c.len,
        args.expand_arg0 == .expand,
        if (env_map) |env| @ptrCast(env.c.ptr) else null,
        if (env_map) |env| env.c.len else 0,
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

    output = try args.allocator.realloc(output, stdout_len + stderr_len);

    return .{
        .term = switch (term_tag) {
            .Exited => .{ .Exited = @intCast(term_code) },
            .Signal => .{ .Signal = term_code },
            .Stopped => .{ .Stopped = term_code },
            .Unknown => .{ .Unknown = term_code },
        },
        .stdout = output[0..stdout_len],
        .stderr = output[stdout_len .. stdout_len + stderr_len],
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

const CStringArray = struct {
    allocator: std.mem.Allocator,

    z: ?[]const [:0]const u8,
    c: []const [*]const u8,

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.c);

        if (self.z) |z| {
            for (z) |ze| self.allocator.free(ze);
            self.allocator.free(z);
        }
    }

    pub fn initDupe(allocator: std.mem.Allocator, array: []const []const u8) !@This() {
        const z = try allocator.alloc([:0]const u8, array.len);
        for (z, array) |*ze, e| ze.* = try allocator.dupeZ(u8, e);

        var self = try initRef(allocator, z);
        self.z = z;

        return self;
    }

    pub fn initRef(allocator: std.mem.Allocator, z: []const [:0]const u8) !@This() {
        const c = try allocator.alloc([*]const u8, z.len);
        for (c, z) |*ce, ze| ce.* = ze.ptr;

        return .{ .allocator = allocator, .z = null, .c = c };
    }

    pub fn initStringStringMap(allocator: std.mem.Allocator, map: anytype) !@This() {
        const z = try allocator.alloc([:0]const u8, map.count() * 2);

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
