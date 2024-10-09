const std = @import("std");

const utils = @import("utils");
const mem = utils.mem;

const abi = @import("../abi.zig");

const externs = struct {
    extern "cizero" fn http_on_webhook(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
    ) void;
};

pub fn OnWebhookCallback(comptime UserData: type) type {
    return fn (
        UserData,
        body: []const u8,
    ) OnWebhookCallbackResponse;
}

pub const OnWebhookCallbackResponse = struct {
    done: bool = false,

    status: std.http.Status = .no_content,
    body: [:0]const u8 = "",
};

pub fn onWebhook(
    comptime UserData: type,
    allocator: std.mem.Allocator,
    callback: OnWebhookCallback(UserData),
    user_data: UserData.Value,
) !void {
    const callback_data = try abi.CallbackData.serialize(UserData, allocator, callback, user_data);
    defer allocator.free(callback_data);

    externs.http_on_webhook("pdk.http.onWebhook.callback", callback_data.ptr, callback_data.len);
}

export fn @"pdk.http.onWebhook.callback"(
    callback_data_ptr: [*]const u8,
    callback_data_len: usize,
    req_body_ptr: [*:0]const u8,
    res_status: *std.http.Status,
    res_body_ptr: *?[*:0]const u8,
    // TODO res_body_len: *usize,
) bool {
    std.debug.assert(res_status.* == .no_content);

    const res = abi.CallbackData
        .deserialize(callback_data_ptr[0..callback_data_len])
        .call(OnWebhookCallback, .{std.mem.span(req_body_ptr)});

    res_status.* = res.status;
    res_body_ptr.* = res.body.ptr;

    return res.done;
}
