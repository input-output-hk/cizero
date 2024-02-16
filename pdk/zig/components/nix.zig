const lib = @import("lib");
const mem = lib.mem;

const abi = @import("../abi.zig");

const externs = struct {
    extern "cizero" fn nix_on_build(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
        installable: [*:0]const u8,
    ) void;

    const NixEvalFormat = enum(u8) { nix, json, raw };

    extern "cizero" fn nix_on_eval(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
        expression: [*:0]const u8,
        format: NixEvalFormat,
    ) void;
};

pub fn onBuild(callback_func_name: [:0]const u8, user_data: anytype, installable: [:0]const u8) !void {
    const user_data_bytes = abi.fixZeroLenSlice(u8, mem.anyAsBytesUnpad(user_data));
    externs.nix_on_build(callback_func_name, user_data_bytes.ptr, user_data_bytes.len, installable);
}

pub const EvalFormat = externs.NixEvalFormat;

pub fn onEval(callback_func_name: [:0]const u8, user_data: anytype, expression: [:0]const u8, format: externs.NixEvalFormat) !void {
    const user_data_bytes = abi.fixZeroLenSlice(u8, mem.anyAsBytesUnpad(user_data));
    externs.nix_on_eval(callback_func_name, user_data_bytes.ptr, user_data_bytes.len, expression, format);
}
