const std = @import("std");

const c = @import("../c.zig");

wasm_engine: ?*c.wasm_engine_t,
wasm_store: ?*c.wasmtime_store,
wasm_context: ?*c.wasmtime_context,
wasm_linker: ?*c.wasmtime_linker,

allocator: std.mem.Allocator,

plugin_name: []const u8,

host_functions: std.StringHashMapUnmanaged(HostFunction),

pub fn deinit(self: *@This()) void {
    const self_on_heap: *@This() = @alignCast(@ptrCast(c.wasmtime_context_get_data(self.wasm_context)));
    self.allocator.destroy(self_on_heap);

    self.host_functions.deinit(self.allocator);

    c.wasmtime_linker_delete(self.wasm_linker);
    c.wasmtime_store_delete(self.wasm_store);
    c.wasm_engine_delete(self.wasm_engine);
}

pub fn init(allocator: std.mem.Allocator, plugin_name: []const u8, module_binary: []const u8, host_functions: std.StringHashMapUnmanaged(HostFunction)) !@This() {
    const wasm_engine = blk: {
        const wasm_config = c.wasm_config_new();
        c.wasmtime_config_epoch_interruption_set(wasm_config, true);

        break :blk c.wasm_engine_new_with_config(wasm_config);
    };
    const wasm_store = c.wasmtime_store_new(wasm_engine, null, null);
    const wasm_context = c.wasmtime_store_context(wasm_store);
    c.wasmtime_context_set_epoch_deadline(wasm_context, 1);

    {
        var wasi_config = c.wasi_config_new();
        std.debug.assert(wasi_config != null);

        c.wasi_config_inherit_argv(wasi_config);
        c.wasi_config_inherit_env(wasi_config);
        c.wasi_config_inherit_stdin(wasi_config);
        c.wasi_config_inherit_stdout(wasi_config);
        c.wasi_config_inherit_stderr(wasi_config);

        try handleError(
            "failed to instantiate WASI",
            c.wasmtime_context_set_wasi(wasm_context, wasi_config),
            null,
        );
    }

    const wasm_linker = c.wasmtime_linker_new(wasm_engine);
    try handleError(
        "failed to link WASI",
        c.wasmtime_linker_define_wasi(wasm_linker),
        null,
    );

    var self = @This(){
        .wasm_engine = wasm_engine,
        .wasm_store = wasm_store,
        .wasm_context = wasm_context,
        .wasm_linker = wasm_linker,
        .allocator = allocator,
        .plugin_name = plugin_name,
        .host_functions = try host_functions.clone(allocator),
    };

    {
        // Make a copy that lives on the heap and therefore has a stable address
        // that we can safely get and dereference from `wasm_context_get_data()`
        // even after `init()` returns and `self` is destroyed.
        // It is crucial that no fields are ever modified
        // as that would lead to changes between the copy on stack and heap.
        // If we need to modify fields in the future, we need to change the `init` function
        // so that it returns a pointer to heap memory, and set that pointer
        // as context data instead of making a copy.
        const self_on_heap = try allocator.create(@This());
        self_on_heap.* = self;
        c.wasmtime_context_set_data(self.wasm_context, self_on_heap);
    }

    {
        var host_functions_iter = self.host_functions.iterator();
        while (host_functions_iter.next()) |entry| {
            std.log.debug("linking host function \"{s}\"…", .{entry.key_ptr.*});

            const host_module_name = "cizero";

            try handleError(
                "failed to define function",
                c.wasmtime_linker_define_func(
                    self.wasm_linker,
                    host_module_name,
                    host_module_name.len,
                    entry.key_ptr.ptr,
                    entry.key_ptr.len,
                    entry.value_ptr.signature,
                    dispatchHostFunction,
                    @constCast(@ptrCast(entry.key_ptr)),
                    null,
                ),
                null,
            );
        }
    }

    {
        var wasm_module: ?*c.wasmtime_module = undefined;
        defer c.wasmtime_module_delete(wasm_module);
        try handleError(
            "failed to compile module",
            c.wasmtime_module_new(wasm_engine, module_binary.ptr, module_binary.len, &wasm_module),
            null,
        );

        try handleError(
            "failed to instantiate module",
            c.wasmtime_linker_module(wasm_linker, wasm_context, null, 0, wasm_module),
            null,
        );
    }

    return self;
}

// TODO split into two so we don't have to keep signature in memory (only needed in `init`)
pub const HostFunction = struct {
    // definition

    signature: *c.wasm_functype_t, // TODO replace with `std.wasm.Type`

    // invocation

    callback: *const Callback,
    user_data: ?*anyopaque,

    pub const Callback = fn (?*anyopaque, []const u8, []u8, []const Val, []Val) anyerror!void;
};

/// Companion to `std.wasm.Valtype`.
pub const Val = union(std.wasm.Valtype) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    v128: [16]u8,

    fn fromWasmtime(v: c.wasmtime_val) @This() {
        return switch (v.kind) {
            c.WASMTIME_I32 => .{ .i32 = v.of.i32 },
            c.WASMTIME_I64 => .{ .i64 = v.of.i64 },
            c.WASMTIME_F32 => .{ .f32 = v.of.f32 },
            c.WASMTIME_F64 => .{ .f64 = v.of.f64 },
            c.WASMTIME_V128 => .{ .v128 = v.of.v128 },
            else => unreachable,
        };
    }
};

fn dispatchHostFunction(
    user_data: ?*anyopaque,
    caller: ?*c.wasmtime_caller,
    inputs: [*c]const c.wasmtime_val,
    inputs_len: usize,
    outputs: [*c]c.wasmtime_val,
    outputs_len: usize,
) callconv(.C) ?*c.wasm_trap_t {
    const self: *@This() = @alignCast(@ptrCast(c.wasmtime_context_get_data(c.wasmtime_caller_context(caller))));

    const memory = getMemoryFromCaller(caller).@"1";

    var input_vals = self.allocator.alloc(Val, inputs_len) catch |err| return errorTrap(err);
    for (input_vals, 0..) |*val, i| val.* = Val.fromWasmtime(inputs[i]);
    defer self.allocator.free(input_vals);

    var output_vals = self.allocator.alloc(Val, outputs_len) catch |err| return errorTrap(err);
    for (output_vals, 0..) |*val, i| val.* = Val.fromWasmtime(outputs[i]);
    defer self.allocator.free(output_vals);

    const host_function_name: *[]const u8 = @alignCast(@ptrCast(user_data));
    const host_function = self.host_functions.getPtr(host_function_name.*) orelse unreachable;
    host_function.callback(
        host_function.user_data,
        self.plugin_name,
        memory,
        input_vals,
        output_vals,
    ) catch |err| return errorTrap(err);

    return null;
}

inline fn errorTrap(err: anyerror) *c.wasm_trap_t {
    const msg = @errorName(err);
    if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
    return c.wasmtime_trap_new(msg, msg.len) orelse std.debug.panic("could not allocate trap: {s}", .{msg});
}

fn getMemoryFromCaller(caller: ?*c.wasmtime_caller) struct { c.wasmtime_memory, []u8 } {
    const context = c.wasmtime_caller_context(caller);

    var memory: c.wasmtime_memory = blk: {
        var item: c.wasmtime_extern = undefined;
        std.debug.assert(c.wasmtime_caller_export_get(caller, "memory", "memory".len, &item));
        std.debug.assert(item.kind == c.WASMTIME_EXTERN_MEMORY);
        break :blk item.of.memory;
    };

    const memory_ptr = c.wasmtime_memory_data(context, &memory);
    const memory_len = c.wasmtime_memory_data_size(context, &memory);
    const memory_slice = memory_ptr[0..memory_len];

    return .{ memory, memory_slice };
}

fn handleExit(err: ?*c.wasmtime_error, trap: ?*c.wasm_trap_t) !bool {
    if (err) |e| {
        var exit_status: c_int = undefined;
        if (c.wasmtime_error_exit_status(e, &exit_status))
            return exit_status == 0;
    }

    try handleError("failed to call function", err, trap);

    return true;
}

pub fn main(self: @This()) !bool {
    var wasi_main: c.wasmtime_func = undefined;
    try handleError(
        "failed to locate default export",
        c.wasmtime_linker_get_default(self.wasm_linker, self.wasm_context, null, 0, &wasi_main),
        null,
    );

    var trap: ?*c.wasm_trap_t = null;
    return handleExit(
        c.wasmtime_func_call(self.wasm_context, &wasi_main, null, 0, null, 0, &trap),
        trap,
    );
}

pub fn call(self: @This(), func_name: [:0]const u8, inputs: []c.wasmtime_val_t, outputs: []c.wasmtime_val_t) !bool {
    var trap: ?*c.wasm_trap_t = null;
    return handleExit(
        c.wasmtime_func_call(
            self.wasm_context,
            blk: {
                var callback_export: c.wasmtime_extern_t = undefined;
                if (!c.wasmtime_linker_get(self.wasm_linker, self.wasm_context, null, 0, func_name, func_name.len, &callback_export)) return error.NoSuchFunction;
                if (callback_export.kind != c.WASMTIME_EXTERN_FUNC) return error.NotAFunction;
                break :blk &callback_export.of.func; // TODO can i return a pointer to block scope?
            },
            inputs.ptr, inputs.len,
            outputs.ptr, outputs.len,
            &trap,
        ),
        trap,
    );
}

fn handleError(
    message: []const u8,
    err: ?*c.wasmtime_error,
    trap: ?*c.wasm_trap_t,
) !void {
    if (err == null and trap == null) return;

    var error_message: c.wasm_byte_vec_t = undefined;
    c.wasm_byte_vec_new_empty(&error_message);
    defer c.wasm_byte_vec_delete(&error_message);

    if (err) |e| {
        defer c.wasmtime_error_delete(e);
        c.wasmtime_error_message(e, &error_message);
        std.log.err("{s}: WASM error: {s}", .{ message, error_message.data });
        return error.WasmError;
    }

    if (trap) |t| {
        defer c.wasm_trap_delete(t);
        c.wasm_trap_message(t, &error_message);
        std.log.err("{s}: WASM trap: {s}", .{ message, error_message.data });
        return error.WasmTrap; // TODO decode wasm_trap_code
    }

    unreachable;
}

test {
    _ = c;
}
