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

pub fn onWebhook(callback_func_name: [:0]const u8, user_data: anytype) void {
    const user_data_bytes = abi.fixZeroLenSlice(u8, mem.anyAsBytesUnpad(user_data));
    externs.http_on_webhook(callback_func_name.ptr, user_data_bytes.ptr, user_data_bytes.len);
}
