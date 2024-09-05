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
        installables: [*]const [*:0]const u8,
        installables_len: usize,
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
    ) bool;
};

pub fn OnBuildCallback(comptime UserData: type) type {
    return fn (UserData, OnBuildResult) void;
}

pub const OnBuildResult = cizero.components.CallbackResult(cizero.components.Nix.Job.Build.Result);

pub fn onBuild(
    comptime UserData: type,
    allocator: std.mem.Allocator,
    callback: OnBuildCallback(UserData),
    user_data: UserData.Value,
    installables: []const [:0]const u8,
) std.mem.Allocator.Error!void {
    const callback_data = try abi.CallbackData.serialize(UserData, allocator, callback, user_data);
    defer allocator.free(callback_data);

    const installable_ptrs = try allocator.alloc([*:0]const u8, installables.len);
    defer allocator.free(installable_ptrs);

    for (installables, installable_ptrs) |installable, *ptr|
        ptr.* = installable.ptr;

    externs.nix_on_build("pdk.nix.onBuild.callback", callback_data.ptr, callback_data.len, installable_ptrs.ptr, installable_ptrs.len);
}

export fn @"pdk.nix.onBuild.callback"(
    callback_data_ptr: [*]const u8,
    callback_data_len: usize,
    err_name: ?[*:0]const u8,
    outputs_ptr: ?[*]const [*:0]const u8,
    outputs_len: usize,
    failed_builds_ptr: ?[*]const [*:0]const u8,
    failed_builds_len: usize,
    failed_dependents_ptr: ?[*]const [*:0]const u8,
    failed_dependents_len: usize,
) void {
    std.debug.assert((outputs_len == 0) == (failed_builds_len != 0 or failed_dependents_len != 0));

    const allocator = std.heap.wasm_allocator;

    var build_result: OnBuildResult = if (err_name) |name|
        .{ .err = std.mem.span(name) }
    else
        .{ .ok = if (outputs_len != 0) blk: {
            const outputs = allocator.alloc([]const u8, outputs_len) catch |err| @panic(@errorName(err));
            for (outputs, outputs_ptr.?[0..outputs_len]) |*output, output_ptr|
                output.* = std.mem.span(output_ptr);

            break :blk .{ .outputs = outputs };
        } else blk: {
            const builds = allocator.alloc([]const u8, failed_builds_len) catch |err| @panic(@errorName(err));
            for (builds, failed_builds_ptr.?[0..failed_builds_len]) |*build, drv_ptr|
                build.* = std.mem.span(drv_ptr);

            const dependents = allocator.alloc([]const u8, failed_dependents_len) catch |err| @panic(@errorName(err));
            for (dependents, failed_dependents_ptr.?[0..failed_dependents_len]) |*dependent, drv_ptr|
                dependent.* = std.mem.span(drv_ptr);

            break :blk .{ .failed = .{
                .builds = builds,
                .dependents = dependents,
            } };
        } };
    defer switch (build_result) {
        .err => |name| allocator.free(name),
        .ok => |*result| result.deinit(allocator),
    };

    abi.CallbackData
        .deserialize(callback_data_ptr[0..callback_data_len])
        .call(OnBuildCallback, .{build_result});
}

pub fn OnEvalCallback(comptime UserData: type) type {
    return fn (UserData, OnEvalResult) void;
}

pub const OnEvalResult = cizero.components.CallbackResult(cizero.components.Nix.Job.Eval.Result);

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
    err_name: ?[*:0]const u8,
    result_ok: ?[*:0]const u8,
    err_msg: ?[*:0]const u8,
    failed_ifds_ptr: ?[*]const [*:0]const u8,
    failed_ifds_len: usize,
    failed_ifd_deps_ptr: ?[*]const [*:0]const u8,
    failed_ifd_deps_len: usize,
) void {
    std.debug.assert((failed_ifds_ptr == null) == (failed_ifds_len == 0));
    std.debug.assert((failed_ifd_deps_ptr == null) == (failed_ifd_deps_len == 0));

    const allocator = std.heap.wasm_allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var eval_result: OnEvalResult = if (err_name) |name|
        .{ .err = std.mem.span(name) }
    else
        .{ .ok = if (result_ok) |r|
            .{ .ok = std.mem.span(r) }
        else if (err_msg) |em|
            .{ .failed = std.mem.span(em) }
        else
            .{ .ifd_failed = .{
                .builds = if (failed_ifds_ptr) |fip| ifds: {
                    const ifds = arena_allocator.alloc([]const u8, failed_ifds_len) catch |err| @panic(@errorName(err));
                    for (ifds, fip[0..failed_ifds_len]) |*ifd, failed_ifd|
                        ifd.* = std.mem.span(failed_ifd);
                    break :ifds ifds;
                } else &.{},
                .dependents = if (failed_ifd_deps_ptr) |fidp| deps: {
                    const deps = arena_allocator.alloc([]const u8, failed_ifd_deps_len) catch |err| @panic(@errorName(err));
                    for (deps, fidp[0..failed_ifd_deps_len]) |*dep, failed_ifd_dep|
                        dep.* = std.mem.span(failed_ifd_dep);
                    break :deps deps;
                } else &.{},
            } } };
    defer switch (eval_result) {
        .err => |name| allocator.free(name),
        .ok => |*result| result.deinit(allocator),
    };

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
) bool {
    return externs.nix_eval_state(if (flake) |f| f else null, expression, format);
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
            const alloc = std.heap.wasm_allocator;

            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();

            const ud_value = eval_callback(ud, arena.allocator(), result);

            if (result != .ok or result.ok != .ok) return;

            var installables = std.ArrayListUnmanaged([:0]const u8){};
            defer {
                for (installables.items) |installable| alloc.free(installable);
                installables.deinit(alloc);
            }

            var lines = std.mem.tokenizeScalar(u8, result.ok.ok, '\n');
            while (lines.next()) |line| {
                const installable = std.mem.concatWithSentinel(alloc, u8, &.{ line, "^*" }, 0) catch |err| @panic(@errorName(err));
                errdefer alloc.free(installable);

                installables.append(alloc, installable) catch |err| @panic(@errorName(err));
            }

            onBuild(UserData, alloc, buildCallback, ud_value, installables.items) catch |err| @panic(@errorName(err));
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

pub const ChildProcessDiagnostics = nix.ChildProcessDiagnostics;
pub const FlakeMetadata = nix.FlakeMetadata;
pub const FlakeMetadataOptions = nix.FlakeMetadataOptions;
pub const FlakePrefetchOptions = nix.FlakePrefetchOptions;

pub const flakeMetadata = nix_impl.flakeMetadata;
pub const flakeMetadataLocks = nix_impl.flakeMetadataLocks;

pub fn lockFlakeRef(
    allocator: std.mem.Allocator,
    flake_ref: []const u8,
    opts: FlakeMetadataOptions,
    diagnostics: *?ChildProcessDiagnostics,
) ![]const u8 {
    const flake_ref_locked = try nix_impl.lockFlakeRef(allocator, flake_ref, opts, diagnostics);

    if (comptime std.log.logEnabled(.debug, log_scope)) {
        if (std.mem.eql(u8, flake_ref_locked, flake_ref))
            log.debug("flake reference {s} is already locked", .{flake_ref})
        else
            log.debug("flake reference {s} locked to {s}", .{ flake_ref, flake_ref_locked });
    }

    return flake_ref_locked;
}
