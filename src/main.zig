const std = @import("std");

const c = @import("c.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    const alloc = gpa.allocator();

    const wasm_engine = c.wasm_engine_new();
    defer c.wasm_engine_delete(wasm_engine);

    const wasm_store = c.wasmtime_store_new(wasm_engine, null, null);
    defer c.wasmtime_store_delete(wasm_store);

    const wasm_context = c.wasmtime_store_context(wasm_store);

    {
        var wasi_config = c.wasi_config_new();
        std.debug.assert(wasi_config != null);

        c.wasi_config_inherit_argv(wasi_config);
        c.wasi_config_inherit_env(wasi_config);
        c.wasi_config_inherit_stdin(wasi_config);
        c.wasi_config_inherit_stdout(wasi_config);
        c.wasi_config_inherit_stderr(wasi_config);

        exitOnError(
            "failed to instantiate WASI",
            c.wasmtime_context_set_wasi(wasm_context, wasi_config),
            null,
        );
    }

    const wasm_linker = c.wasmtime_linker_new(wasm_engine);
    defer c.wasmtime_linker_delete(wasm_linker);
    exitOnError(
        "failed to link wasi",
        c.wasmtime_linker_define_wasi(wasm_linker),
        null,
    );

    {
        const host_module_name = "cizero";

        {
            const name = "add";
            exitOnError(
                "failed to define function \"" ++ name ++ "\"",
                c.wasmtime_linker_define_func(
                    wasm_linker,
                    host_module_name,
                    host_module_name.len,
                    name,
                    name.len,
                    c.wasm_functype_new_2_1(
                        c.wasm_valtype_new_i32(),
                        c.wasm_valtype_new_i32(),
                        c.wasm_valtype_new_i32(),
                    ),
                    wasmAdd,
                    null,
                    null,
                ),
                null,
            );
        }
    }

    var wasm_module: ?*c.wasmtime_module_t = undefined;
    defer c.wasmtime_module_delete(wasm_module);
    {
        const binary = try std.fs.cwd().readFileAlloc(alloc, "zig-out/bin/foo.wasm", std.math.maxInt(usize));
        defer alloc.free(binary);

        exitOnError(
            "failed to compile module",
            c.wasmtime_module_new(wasm_engine, binary.ptr, binary.len, &wasm_module),
            null,
        );
    }

    exitOnError(
        "failed to instantiate module",
        c.wasmtime_linker_module(wasm_linker, wasm_context, null, 0, wasm_module),
        null,
    );

    {
        var wasm_export_fib: c.wasmtime_extern_t = undefined;
        {
            const name = "fib";
            std.debug.assert(c.wasmtime_linker_get(wasm_linker, wasm_context, null, 0, name, name.len, &wasm_export_fib));
            std.debug.assert(wasm_export_fib.kind == c.WASMTIME_EXTERN_FUNC);
        }

        const args = [_]c.wasmtime_val_t{
            .{
                .kind = c.WASMTIME_I32,
                .of = .{ .i32 = 12 },
            },
        };
        var result: c.wasmtime_val_t = undefined;

        var trap: ?*c.wasm_trap_t = null;
        exitOnError(
            "failed to call function",
            c.wasmtime_func_call(wasm_context, &wasm_export_fib.of.func, &args, args.len, &result, 1, &trap),
            trap,
        );

        std.debug.print("Fibonacci result: {d}\n", .{result.of.i32});
    }

    if (false) {
        var wasi_main: c.wasmtime_func_t = undefined;
        exitOnError(
            "failed to locate default export",
            c.wasmtime_linker_get_default(wasm_linker, wasm_context, null, 0, &wasi_main),
            null,
        );

        // var result: c.wasmtime_val_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        exitOnError(
            "failed to call main function",
            c.wasmtime_func_call(wasm_context, &wasi_main, null, 0, null, 0, &trap),
            trap,
        );

        // std.debug.print("WASI exit status: {d}\n", .{result.of.i32});
    }
}

fn exitOnError(
    message: []const u8,
    err: ?*c.wasmtime_error_t,
    trap: ?*c.wasm_trap_t,
) void {
    if (err != null or trap != null) {
        std.debug.print("error: {s}\n", .{message});
    }

    if (err) |e| {
        var error_message: c.wasm_byte_vec_t = undefined;
        c.wasmtime_error_message(e, &error_message);
        defer c.wasm_byte_vec_delete(&error_message);

        c.wasmtime_error_delete(e);

        std.debug.print("{s}\n", .{error_message.data});
    }

    if (trap) |t| {
        var error_message: c.wasm_byte_vec_t = undefined;
        c.wasm_trap_message(t, &error_message);
        defer c.wasm_byte_vec_delete(&error_message);

        c.wasm_trap_delete(t);

        std.debug.print("{s}\n", .{error_message.data});
    }

    if (err != null or trap != null) std.process.exit(1);
}

fn wasmAdd(
    _: ?*anyopaque,
    _: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    args_len: usize,
    results: [*c]c.wasmtime_val_t,
    results_len: usize,
) callconv(.C) ?*c.wasm_trap_t {
    std.debug.assert(args_len == 2);
    std.debug.assert(results_len == 1);

    results.* = .{
        .kind = c.WASMTIME_I32,
        .of = .{ .i32 = args[0].of.i32 + args[1].of.i32 },
    };

    return null;
}

test {
    _ = c;
}
