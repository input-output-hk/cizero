const std = @import("std");

const cizero = @import("cizero");

const lib = @import("lib");
const enums = lib.enums;
const mem = lib.mem;
const meta = lib.meta;
const nix = lib.nix;

const abi = @import("../abi.zig");

const process = @import("process.zig");

const log_scope = .nix;
const log = std.log.scoped(log_scope);

const externs = struct {
    extern "cizero" fn nix_on_build(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
        installable: [*:0]const u8,
    ) void;

    // only powers of two >= 8 are compatible with the ABI
    const EvalFormat = enums.EnsurePowTag(cizero.components.Nix.EvalFormat, 8);

    extern "cizero" fn nix_on_eval(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
        flake: ?[*:0]const u8,
        expression: [*:0]const u8,
        format: @This().EvalFormat,
    ) void;

    extern "cizero" fn nix_build_state(
        installable: [*:0]const u8,
    ) bool;

    extern "cizero" fn nix_eval_state(
        flake: ?[*:0]const u8,
        expression: [*:0]const u8,
        format: @This().EvalFormat,
    ) meta.EnsurePowBits(std.meta.Tag(std.meta.Tag(cizero.components.Nix.EvalState)), 8);
};

pub fn OnBuildCallback(comptime UserData: type) type {
    return fn (UserData, OnBuildResult) void;
}

pub const OnBuildResult = cizero.components.Nix.Job.Build.Result;

pub fn onBuild(
    comptime UserData: type,
    allocator: std.mem.Allocator,
    callback: OnBuildCallback(UserData),
    user_data: UserData.Value,
    installable: [:0]const u8,
) std.mem.Allocator.Error!void {
    const callback_data = try abi.CallbackData.serialize(UserData, allocator, callback, user_data);
    defer allocator.free(callback_data);

    externs.nix_on_build("pdk.nix.onBuild.callback", callback_data.ptr, callback_data.len, installable);
}

export fn @"pdk.nix.onBuild.callback"(
    callback_data_ptr: [*]const u8,
    callback_data_len: usize,
    outputs_ptr: [*]const [*:0]const u8,
    outputs_len: usize,
    failed_deps_ptr: [*]const [*:0]const u8,
    failed_deps_len: usize,
) void {
    const allocator = std.heap.wasm_allocator;

    var build_result: OnBuildResult = if (failed_deps_len == 0) blk: {
        const outputs = allocator.alloc([]const u8, outputs_len) catch |err| @panic(@errorName(err));
        for (outputs, outputs_ptr[0..outputs_len]) |*output, output_ptr|
            output.* = std.mem.span(output_ptr);
        break :blk .{ .outputs = outputs };
    } else blk: {
        const deps_failed = allocator.alloc([]const u8, failed_deps_len) catch |err| @panic(@errorName(err));
        for (deps_failed, failed_deps_ptr[0..failed_deps_len]) |*dep_failed, dep_failed_ptr|
            dep_failed.* = std.mem.span(dep_failed_ptr);
        break :blk .{ .deps_failed = deps_failed };
    };
    defer build_result.deinit(allocator);

    abi.CallbackData
        .deserialize(callback_data_ptr[0..callback_data_len])
        .call(OnBuildCallback, .{build_result});
}

pub fn OnEvalCallback(comptime UserData: type) type {
    return fn (UserData, OnEvalResult) void;
}

pub const OnEvalResult = cizero.components.Nix.Job.Eval.Result;

pub const EvalFormat = externs.EvalFormat;

pub fn onEval(
    comptime UserData: type,
    allocator: std.mem.Allocator,
    callback: OnEvalCallback(UserData),
    user_data: UserData.Value,
    flake: ?[:0]const u8,
    expression: [:0]const u8,
    format: externs.EvalFormat,
) std.mem.Allocator.Error!void {
    const callback_data = try abi.CallbackData.serialize(UserData, allocator, callback, user_data);
    defer allocator.free(callback_data);

    externs.nix_on_eval("pdk.nix.onEval.callback", callback_data.ptr, callback_data.len, if (flake) |f| f else null, expression, format);
}

export fn @"pdk.nix.onEval.callback"(
    callback_data_ptr: [*]const u8,
    callback_data_len: usize,
    result: ?[*:0]const u8,
    err_msg: ?[*:0]const u8,
    failed_ifd: ?[*:0]const u8,
    failed_ifd_deps_ptr: ?[*]const [*:0]const u8,
    failed_ifd_deps_len: usize,
) void {
    std.debug.assert((failed_ifd_deps_ptr == null) == (failed_ifd_deps_len == 0));

    const allocator = std.heap.wasm_allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    const eval_result: OnEvalResult = if (result) |r|
        .{ .ok = std.mem.span(r) }
    else if (err_msg) |em|
        .{ .failed = std.mem.span(em) }
    else if (failed_ifd_deps_ptr) |fidp|
        .{ .ifd_deps_failed = .{
            .ifd = std.mem.span(failed_ifd.?),
            .drvs = drvs: {
                const drvs = arena_allocator.alloc([]const u8, failed_ifd_deps_len) catch |err| @panic(@errorName(err));
                for (drvs, fidp[0..failed_ifd_deps_len]) |*drv, dep|
                    drv.* = std.mem.span(dep);
                break :drvs drvs;
            },
        } }
    else if (failed_ifd) |fi|
        .{ .ifd_failed = std.mem.span(fi) }
    else
        .ifd_too_deep;

    abi.CallbackData
        .deserialize(callback_data_ptr[0..callback_data_len])
        .call(OnEvalCallback, .{eval_result});
}

pub fn buildState(installable: [:0]const u8) bool {
    return externs.nix_build_state(installable);
}

pub fn evalState(
    flake: ?[:0]const u8,
    expression: [:0]const u8,
    format: @This().EvalFormat,
) ?std.meta.Tag(cizero.components.Nix.EvalState) {
    const state = externs.nix_eval_state(
        if (flake) |f| f else null,
        expression,
        format,
    );
    return if (state == 0) null else @enumFromInt(state - 1);
}

pub fn onEvalBuild(
    comptime UserData: type,
    allocator: std.mem.Allocator,
    eval_callback: fn (UserData, std.mem.Allocator, OnEvalResult) UserData.Value,
    build_callback: OnBuildCallback(UserData),
    user_data: UserData.Value,
    flake: ?[:0]const u8,
    expression: [:0]const u8,
) std.mem.Allocator.Error!void {
    const evalCallback = struct {
        fn evalCallback(ud: UserData, result: OnEvalResult) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
            defer arena.deinit();

            const ud_value = eval_callback(ud, arena.allocator(), result);

            if (result == .ok) {
                const alloc = std.heap.wasm_allocator;

                const installable_z = std.mem.concatWithSentinel(alloc, u8, &.{ result.ok, "^*" }, 0) catch |err| @panic(@errorName(err));
                defer alloc.free(installable_z);

                onBuild(UserData, alloc, buildCallback, ud_value, installable_z) catch |err| @panic(@errorName(err));
            }
        }

        fn buildCallback(ud: UserData, result: OnBuildResult) void {
            build_callback(ud, result);
        }
    }.evalCallback;

    try onEval(UserData, allocator, evalCallback, user_data, flake, expression, .raw);
}

const nix_impl = nix.impl(
    process.exec,
    log_scope,
);

pub const flakeMetadata = nix_impl.flakeMetadata;

pub const flakeMetadataLocks = nix_impl.flakeMetadataLocks;

pub fn lockFlakeRef(allocator: std.mem.Allocator, flake_ref: []const u8, opts: nix.FlakeMetadataOptions) ![]const u8 {
    const flake_ref_locked = nix_impl.lockFlakeRef(allocator, flake_ref, opts);

    if (comptime std.log.logEnabled(.debug, log_scope)) {
        if (std.mem.eql(u8, flake_ref_locked, flake_ref))
            log.debug("flake reference {s} is already locked", .{flake_ref})
        else
            log.debug("flake reference {s} locked to {s}", .{ flake_ref, flake_ref_locked });
    }

    return flake_ref_locked;
}
