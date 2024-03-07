const std = @import("std");

const lib = @import("lib");
const mem = lib.mem;

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
        abi.CallbackData.UserDataPtr(UserData),
        body: []const u8,
    ) OnWebhookCallbackResponse;
}

pub const OnWebhookCallbackResponse = struct {
    done: bool = false,

    status: u16 = 204,
    body: [:0]const u8 = "",
};

pub fn onWebhook(
    comptime UserData: type,
    allocator: std.mem.Allocator,
    callback: OnWebhookCallback(UserData),
    user_data: abi.CallbackDataConst.UserDataPtr(UserData),
) !void {
    const callback_data = try (abi.CallbackDataConst.init(UserData, callback, user_data)).serialize(allocator);
    defer allocator.free(callback_data);

    externs.http_on_webhook("pdk.http.onWebhook.callback", callback_data.ptr, callback_data.len);
}

export fn @"pdk.http.onWebhook.callback"(
    callback_data_ptr: [*]u8,
    callback_data_len: usize,
    req_body_ptr: [*:0]const u8,
    res_status: *u16,
    res_body_ptr: *?[*:0]const u8,
    // TODO res_body_len: *usize,
) bool {
    std.debug.assert(res_status.* == 204);

    const res = abi.CallbackData
        .deserialize(callback_data_ptr[0..callback_data_len])
        .call(OnWebhookCallback, .{std.mem.span(req_body_ptr)});

    res_status.* = res.status;
    res_body_ptr.* = res.body.ptr;

    return res.done;
}
