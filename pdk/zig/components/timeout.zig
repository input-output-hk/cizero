const std = @import("std");

const lib = @import("lib");
const mem = lib.mem;

const abi = @import("../abi.zig");

const externs = struct {
    extern "cizero" fn timeout_on_cron(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
        cron: [*:0]const u8,
    ) i64;

    extern "cizero" fn timeout_on_timestamp(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
        timestamp: i64,
    ) void;
};

pub fn OnCronCallback(comptime UserData: type) type {
    return fn (UserData) bool;
}

pub fn onCron(
    comptime UserData: type,
    allocator: std.mem.Allocator,
    callback: OnCronCallback(UserData),
    user_data: UserData.Value,
    cron_expr: [:0]const u8,
) !i64 {
    const callback_data = try abi.CallbackData.serialize(UserData, allocator, callback, user_data);
    defer allocator.free(callback_data);

    return externs.timeout_on_cron("pdk.timeout.onCron.callback", callback_data.ptr, callback_data.len, cron_expr.ptr);
}

export fn @"pdk.timeout.onCron.callback"(callback_data_ptr: [*]const u8, callback_data_len: usize) bool {
    return abi.CallbackData
        .deserialize(callback_data_ptr[0..callback_data_len])
        .call(OnCronCallback, .{});
}

pub fn OnTimestampCallback(comptime UserData: type) type {
    return fn (UserData) void;
}

pub fn onTimestamp(
    comptime UserData: type,
    allocator: std.mem.Allocator,
    callback: OnTimestampCallback(UserData),
    user_data: UserData.Value,
    timestamp_ms: i64,
) !void {
    const callback_data = try abi.CallbackData.serialize(UserData, allocator, callback, user_data);
    defer allocator.free(callback_data);

    externs.timeout_on_timestamp("pdk.timeout.onTimestamp.callback", callback_data.ptr, callback_data.len, timestamp_ms);
}

export fn @"pdk.timeout.onTimestamp.callback"(callback_data_ptr: [*]const u8, callback_data_len: usize) void {
    abi.CallbackData
        .deserialize(callback_data_ptr[0..callback_data_len])
        .call(OnTimestampCallback, .{});
}
