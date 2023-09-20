const std = @import("std");

const c = @import("c.zig");

const Self = @This();

wasm_engine: ?*c.wasm_engine_t,
wasm_store: ?*c.wasmtime_store_t,
wasm_context: ?*c.wasmtime_context_t,
wasm_linker: ?*c.wasmtime_linker_t,

pub fn deinit(self: Self) void {
    c.wasmtime_linker_delete(self.wasm_linker);
    c.wasmtime_store_delete(self.wasm_store);
    c.wasm_engine_delete(self.wasm_engine);
}

pub fn init(module_binary: []const u8) !Self {
    const wasm_engine = c.wasm_engine_new();
    const wasm_store = c.wasmtime_store_new(wasm_engine, null, null);
    const wasm_context = c.wasmtime_store_context(wasm_store);

    {
        var wasi_config = c.wasi_config_new();
        std.debug.assert(wasi_config != null);

        c.wasi_config_inherit_argv(wasi_config);
        c.wasi_config_inherit_env(wasi_config);
        c.wasi_config_inherit_stdin(wasi_config);
        c.wasi_config_inherit_stdout(wasi_config);
        c.wasi_config_inherit_stderr(wasi_config);

        if (c.wasmtime_context_set_wasi(wasm_context, wasi_config)) |err|
            return handleError("failed to instantiate WASI", err, null);
    }

    const wasm_linker = c.wasmtime_linker_new(wasm_engine);
    if (c.wasmtime_linker_define_wasi(wasm_linker)) |err|
        return handleError("failed to link WASI", err, null);

    try linkHostFunctions(wasm_linker);

    {
        var wasm_module: ?*c.wasmtime_module_t = undefined;
        defer c.wasmtime_module_delete(wasm_module);
        if (c.wasmtime_module_new(wasm_engine, module_binary.ptr, module_binary.len, &wasm_module)) |err|
            return handleError("failed to compile module", err, null);

        if (c.wasmtime_linker_module(wasm_linker, wasm_context, null, 0, wasm_module)) |err|
            return handleError("failed to instantiate module", err, null);
    }

    return .{
        .wasm_engine = wasm_engine,
        .wasm_store = wasm_store,
        .wasm_context = wasm_context,
        .wasm_linker = wasm_linker,
    };
}

fn linkHostFunctions(wasm_linker: ?*c.wasmtime_linker_t) !void {
    const host_funcs = struct {
        fn add(
            _: ?*anyopaque,
            _: ?*c.wasmtime_caller_t,
            inputs: [*c]const c.wasmtime_val_t,
            inputs_len: usize,
            outputs: [*c]c.wasmtime_val_t,
            outputs_len: usize,
        ) callconv(.C) ?*c.wasm_trap_t {
            std.debug.assert(inputs_len == 2);
            std.debug.assert(outputs_len == 1);

            outputs.* = .{
                .kind = c.WASMTIME_I32,
                .of = .{ .i32 = inputs[0].of.i32 + inputs[1].of.i32 },
            };

            return null;
        }

        fn toUpper(
            _: ?*anyopaque,
            caller: ?*c.wasmtime_caller_t,
            inputs: [*c]const c.wasmtime_val_t,
            inputs_len: usize,
            _: [*c]c.wasmtime_val_t,
            outputs_len: usize,
        ) callconv(.C) ?*c.wasm_trap_t {
            std.debug.assert(inputs_len == 1);
            std.debug.assert(outputs_len == 0);

            var memory = getMemoryFromCaller(caller).@"1";

            const buf_ptr: [*c]u8 = &memory[@intCast(inputs[0].of.i32)];
            var buf = std.mem.span(buf_ptr);
            _ = std.ascii.upperString(buf, buf);

            return null;
        }
    };

    const host_module_name = "cizero";

    inline for ([_]struct{
        []const u8,
        ?*c.wasm_functype_t,
        c.wasmtime_func_callback_t,
    }{
        .{
            "add",
            c.wasm_functype_new_2_1(
                c.wasm_valtype_new_i32(),
                c.wasm_valtype_new_i32(),
                c.wasm_valtype_new_i32(),
            ),
            host_funcs.add,
        },
        .{
            "toUpper",
            c.wasm_functype_new_1_0(
                c.wasm_valtype_new_i32(),
            ),
            host_funcs.toUpper,
        },
    }) |def| if (c.wasmtime_linker_define_func(
        wasm_linker,
        host_module_name,
        host_module_name.len,
        def.@"0".ptr,
        def.@"0".len,
        def.@"1",
        def.@"2",
        null,
        null,
    )) |err| return handleError("failed to define function", err, null);
}

fn getMemoryFromCaller(caller: ?*c.wasmtime_caller_t) struct { c.wasmtime_memory, []u8 } {
    const context = c.wasmtime_caller_context(caller);

    var memory: c.wasmtime_memory_t = blk: {
        var item: c.wasmtime_extern_t = undefined;
        const ok = c.wasmtime_caller_export_get(caller, "memory", "memory".len, &item);
        std.debug.assert(ok);
        std.debug.assert(item.kind == c.WASMTIME_EXTERN_MEMORY);
        break :blk item.of.memory;
    };

    const memory_ptr = c.wasmtime_memory_data(context, &memory);
    const memory_len = c.wasmtime_memory_data_size(context, &memory);
    const memory_slice = memory_ptr[0..memory_len];

    return .{ memory, memory_slice };
}

pub fn fib(self: Self, n: i32) !i32 {
    var wasm_export_fib: c.wasmtime_extern_t = undefined;
    {
        const name = "fib";
        std.debug.assert(c.wasmtime_linker_get(self.wasm_linker, self.wasm_context, null, 0, name, name.len, &wasm_export_fib));
        std.debug.assert(wasm_export_fib.kind == c.WASMTIME_EXTERN_FUNC);
    }

    const inputs = [_]c.wasmtime_val_t{
        .{
            .kind = c.WASMTIME_I32,
            .of = .{ .i32 = n },
        },
    };
    var output: c.wasmtime_val_t = undefined;

    var trap: ?*c.wasm_trap_t = null;
    if (c.wasmtime_func_call(self.wasm_context, &wasm_export_fib.of.func, &inputs, inputs.len, &output, 1, &trap)) |err|
        return handleError("failed to call function", err, trap);

    return output.of.i32;
}

pub fn main(self: Self) !c_int {
    var wasi_main: c.wasmtime_func_t = undefined;
    if (c.wasmtime_linker_get_default(self.wasm_linker, self.wasm_context, null, 0, &wasi_main)) |err|
        return handleError("failed to locate default export", err, null);

    var trap: ?*c.wasm_trap_t = null;
    const err = c.wasmtime_func_call(self.wasm_context, &wasi_main, null, 0, null, 0, &trap);

    var exit_status: c_int = undefined;
    if (c.wasmtime_error_exit_status(err, &exit_status)) {
        return exit_status;
    } else {
        return handleError("failed to call main function", err, trap);
    }
}

fn handleError(
    message: []const u8,
    err: ?*c.wasmtime_error_t,
    trap: ?*c.wasm_trap_t,
) error{ WasmError, WasmTrap } {
    std.debug.assert(err != null or trap != null);

    var error_message: c.wasm_byte_vec_t = undefined;
    c.wasm_byte_vec_new_empty(&error_message);
    defer c.wasm_byte_vec_delete(&error_message);

    if (err) |e| {
        defer c.wasmtime_error_delete(e);
        c.wasmtime_error_message(e, &error_message);
        std.log.err("error: {s}\n{s}\n", .{ message, error_message.data });
        return error.WasmError;
    }

    if (trap) |t| {
        defer c.wasm_trap_delete(t);
        c.wasm_trap_message(t, &error_message);
        std.log.err("trap: {s}\n{s}\n", .{ message, error_message.data });
        return error.WasmTrap; // TODO decode wasm_trap_code
    }

    unreachable;
}

test {
    _ = c;
}
