const std = @import("std");

const c = @import("../c.zig");

const State = @import("State.zig");

const Self = @This();

wasm_engine: ?*c.wasm_engine_t,
wasm_store: ?*c.wasmtime_store,
wasm_context: ?*c.wasmtime_context,
wasm_linker: ?*c.wasmtime_linker,

state: *State,

allocator: std.mem.Allocator,

pub fn deinit(self: Self) void {
    const self_on_heap: *Self = @alignCast(@ptrCast(c.wasmtime_context_get_data(self.wasm_context)));
    self.allocator.destroy(self_on_heap);

    c.wasmtime_linker_delete(self.wasm_linker);
    c.wasmtime_store_delete(self.wasm_store);
    c.wasm_engine_delete(self.wasm_engine);
}

pub fn init(allocator: std.mem.Allocator, module_binary: []const u8, state: *State) !Self {
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

    var self = Self{
        .wasm_engine = wasm_engine,
        .wasm_store = wasm_store,
        .wasm_context = wasm_context,
        .wasm_linker = wasm_linker,
        .state = state,
        .allocator = allocator,
    };

    {
        // Make a copy that lives on the heap and therefore has a stable address
        // that we can safely get and dereference from `wasm_context_get_data()`
        // even after `init()` returns and `self` is destroyed.
        // As `Self`'s fields are all pointers,
        // there is no state that could differ between copies.
        // Unless of course the user manually changes the pointers,
        // but that that is a bad idea should be reasonably obvious.
        const self_on_heap = try allocator.create(Self);
        self_on_heap.* = self;
        c.wasmtime_context_set_data(self.wasm_context, self_on_heap);
    }

    try self.linkHostFunctions();

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

fn linkHostFunctions(self: Self) !void {
    const host_funcs = struct {
        fn add(
            _: ?*anyopaque,
            _: ?*c.wasmtime_caller,
            inputs: [*c]const c.wasmtime_val,
            inputs_len: usize,
            outputs: [*c]c.wasmtime_val,
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
            caller: ?*c.wasmtime_caller,
            inputs: [*c]const c.wasmtime_val,
            inputs_len: usize,
            _: [*c]c.wasmtime_val,
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

        fn yieldTimeout(
            _: ?*anyopaque,
            caller: ?*c.wasmtime_caller,
            inputs: [*c]const c.wasmtime_val,
            inputs_len: usize,
            _: [*c]c.wasmtime_val,
            outputs_len: usize,
        ) callconv(.C) ?*c.wasm_trap_t {
            std.debug.assert(inputs_len == 2);
            std.debug.assert(outputs_len == 0);

            const context = c.wasmtime_caller_context(caller);
            const context_data = c.wasmtime_context_get_data(context);

            var memory = getMemoryFromCaller(caller).@"1";

            var this: *Self = @alignCast(@ptrCast(context_data));
            this.state.setCallback(
                std.mem.span(@as(
                    [*c]const u8,
                    &memory[@intCast(inputs[0].of.i32)],
                )),
                .{ .timeout_ms = @intCast(inputs[1].of.i64) },
            ) catch |err| std.debug.panic("failed to set callback: {any}\n", .{err});

            c.wasmtime_engine_increment_epoch(this.wasm_engine);

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
        .{
            "yieldTimeout",
            c.wasm_functype_new_2_0(
                c.wasm_valtype_new_i32(),
                c.wasm_valtype_new_i64(),
            ),
            host_funcs.yieldTimeout,
        },
    }) |def| try handleError(
        "failed to define function",
        c.wasmtime_linker_define_func(
            self.wasm_linker,
            host_module_name,
            host_module_name.len,
            def.@"0".ptr,
            def.@"0".len,
            def.@"1",
            def.@"2",
            null,
            null,
        ),
        null,
    );
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

pub const ExitStatus = union(enum) {
    yield,
    success,
    failure,
};

fn handleExit(self: Self, err: ?*c.wasmtime_error, trap: ?*c.wasm_trap_t) !ExitStatus {
    if (trap) |t| {
        var code: c.wasmtime_trap_code_t = undefined;
        if (
            c.wasmtime_trap_code(t, &code) and
            code == c.WASMTIME_TRAP_CODE_INTERRUPT and
            self.state.callback != null
        ) {
            std.log.info("plugin yields", .{});
            return .yield;
        }
    }

    if (err) |e| {
        var exit_status: c_int = undefined;
        if (c.wasmtime_error_exit_status(e, &exit_status))
            return if (exit_status == 0) .success else .failure;
        try handleError("failed to call function", err, trap);
        unreachable;
    }

    return .success;
}

pub fn main(self: Self) !ExitStatus {
    var wasi_main: c.wasmtime_func = undefined;
    try handleError(
        "failed to locate default export",
        c.wasmtime_linker_get_default(self.wasm_linker, self.wasm_context, null, 0, &wasi_main),
        null,
    );

    var trap: ?*c.wasm_trap_t = null;
    return self.handleExit(
        c.wasmtime_func_call(self.wasm_context, &wasi_main, null, 0, null, 0, &trap),
        trap,
    );
}

pub fn handleEvent(self: Self, event: State.Callback.Event) !ExitStatus {
    const callback_func: c.wasmtime_func_t = if (self.state.callback) |cb| blk: {
        if (std.meta.activeTag(event) != cb.condition) return error.UnmatchedEvent;

        var callback_export: c.wasmtime_extern_t = undefined;
        if (!c.wasmtime_linker_get(self.wasm_linker, self.wasm_context, null, 0, cb.func_name, cb.func_name.len, &callback_export)) return error.NoCallback;
        if (callback_export.kind != c.WASMTIME_EXTERN_FUNC) return error.BadCallback;
        break :blk callback_export.of.func;
    } else return error.PluginCannotContinue;

    var inputs: []c.wasmtime_val_t = &.{};
    var outputs: []c.wasmtime_val_t = &.{};

    switch (event) {
        .timeout_ms => {},
    }

    var trap: ?*c.wasm_trap_t = null;
    const err = c.wasmtime_func_call(self.wasm_context, &callback_func, inputs.ptr, inputs.len, outputs.ptr, outputs.len, &trap);

    try self.state.unsetCallback();

    return self.handleExit(err, trap);
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
