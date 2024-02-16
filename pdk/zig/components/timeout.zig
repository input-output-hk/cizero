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

pub fn onCron(callback_func_name: [:0]const u8, user_data: anytype, cron_expr: [:0]const u8) i64 {
    const user_data_bytes = abi.fixZeroLenSlice(u8, mem.anyAsBytesUnpad(user_data));
    return externs.timeout_on_cron(callback_func_name.ptr, user_data_bytes.ptr, user_data_bytes.len, cron_expr.ptr);
}

pub fn onTimestamp(callback_func_name: [:0]const u8, user_data: anytype, timestamp_ms: i64) void {
    const user_data_bytes = abi.fixZeroLenSlice(u8, mem.anyAsBytesUnpad(user_data));
    externs.timeout_on_timestamp(callback_func_name.ptr, user_data_bytes.ptr, user_data_bytes.len, timestamp_ms);
}
