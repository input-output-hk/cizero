const std = @import("std");

const c = @import("c.zig");
const wasm_edge = @import("wasm_edge.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.c_allocator,
    };
    const alloc = gpa.allocator();

    if (false) c.WasmEdge_LogSetDebugLevel();

    var wasm_host_module = blk: {
        var host_module = wasm_edge.ModuleInstance.init("cizero");

        {
            var func_inst = wasm_edge.FunctionInstance.init(
                &.{c.WasmEdge_ValType_I32, c.WasmEdge_ValType_I32},
                &.{c.WasmEdge_ValType_I32},
                wasmAdd,
                null,
                0,
            );
            defer func_inst.deinit();
            host_module.addFunction("add", func_inst.func_inst);
        }

        {
            var func_inst = wasm_edge.FunctionInstance.init(
                &.{c.WasmEdge_ValType_I32, c.WasmEdge_ValType_I32},
                &.{c.WasmEdge_ValType_I32},
                wasmToUpper,
                @constCast(&alloc),
                0,
            );
            defer func_inst.deinit();
            host_module.addFunction("toUpper", func_inst.func_inst);
        }

        break :blk host_module;
    };
    defer wasm_host_module.deinit();

    // call a wasm function
    {
        const wasm_vm = blk: {
            const wasm_conf = c.WasmEdge_ConfigureCreate();
            defer c.WasmEdge_ConfigureDelete(wasm_conf);
            c.WasmEdge_ConfigureAddHostRegistration(wasm_conf, c.WasmEdge_HostRegistration_Wasi);

            const vm = c.WasmEdge_VMCreate(wasm_conf, null);

            {
                const res = c.WasmEdge_VMRegisterModuleFromImport(vm, wasm_host_module.mod_inst);
                if (!c.WasmEdge_ResultOK(res)) {
                    std.debug.panic("Could not register host module: {s}\n", .{c.WasmEdge_ResultGetMessage(res)});
                }
            }

            break :blk vm;
        };
        defer c.WasmEdge_VMDelete(wasm_vm);

        var returns: [1]c.WasmEdge_Value = undefined;
        const res = blk: {
            const params = [_]c.WasmEdge_Value{
                c.WasmEdge_ValueGenI32(12),
            };
            const func_name = c.WasmEdge_StringCreateByCString("fib");
            defer c.WasmEdge_StringDelete(func_name);
            break :blk c.WasmEdge_VMRunWasmFromFile(wasm_vm, "foo.wasm", func_name, &params, params.len, &returns, returns.len);
        };

        if (c.WasmEdge_ResultOK(res)) {
            std.debug.print("Fibonacci result: {d}\n", .{c.WasmEdge_ValueGetI32(returns[0])});
        } else {
            std.debug.print("Fibonacci error: {s}\n", .{c.WasmEdge_ResultGetMessage(res)});
        }
    }

    // run WASI main
    {
        const wasm_vm = blk: {
            const wasm_conf = c.WasmEdge_ConfigureCreate();
            defer c.WasmEdge_ConfigureDelete(wasm_conf);

            const vm = c.WasmEdge_VMCreate(wasm_conf, null);

            {
                const res = c.WasmEdge_VMRegisterModuleFromImport(vm, wasm_host_module.mod_inst);
                if (!c.WasmEdge_ResultOK(res)) {
                    std.debug.panic("Could not register host module: {s}\n", .{c.WasmEdge_ResultGetMessage(res)});
                }
            }

            break :blk vm;
        };
        defer c.WasmEdge_VMDelete(wasm_vm);

        const wasi_module = blk: {
            const wasi_args = [_][*c]const u8{"hello", "world"}; // FIXME make args work
            const wasi_envs = [_][*c]const u8{};
            const wasi_preopens = [_][*c]const u8{};

            break :blk c.WasmEdge_ModuleInstanceCreateWASI(
                &wasi_args,
                wasi_args.len,
                &wasi_envs,
                wasi_envs.len,
                &wasi_preopens,
                wasi_preopens.len,
            );
        };
        defer c.WasmEdge_ModuleInstanceDelete(wasi_module);

        // register WASI module
        {
            const res = c.WasmEdge_VMRegisterModuleFromImport(wasm_vm, wasi_module);
            if (!c.WasmEdge_ResultOK(res)) {
                std.debug.panic("Could not register WASI module: {s}\n", .{c.WasmEdge_ResultGetMessage(res)});
            }
        }

        // run main
        const res_main = blk: {
            const func_name = c.WasmEdge_StringCreateByCString("main");
            defer c.WasmEdge_StringDelete(func_name);
            break :blk c.WasmEdge_VMRunWasmFromFile(
                wasm_vm,
                "foo.wasm",
                func_name,
                &[_]c.WasmEdge_Value{}, 0,
                &[_]c.WasmEdge_Value{}, 0,
            );
        };
        if (!c.WasmEdge_ResultOK(res_main)) {
            std.debug.panic("Could not run WASI main: {s}\n", .{c.WasmEdge_ResultGetMessage(res_main)});
        }

        std.debug.print("WASI exit code: {d}\n", .{c.WasmEdge_ModuleInstanceWASIGetExitCode(wasi_module)});
    }
}

fn wasmAdd(
    _: ?*anyopaque,
    _: ?*const c.WasmEdge_CallingFrameContext,
    in: [*c]const c.WasmEdge_Value,
    out: [*c]c.WasmEdge_Value,
) callconv(.C) c.WasmEdge_Result {
    out.* = c.WasmEdge_ValueGenI32(
        c.WasmEdge_ValueGetI32(in[0])
        +
        c.WasmEdge_ValueGetI32(in[1])
    );
    return c.WasmEdge_Result_Success;
}

fn wasmToUpper(
    data: ?*anyopaque,
    frame: ?*const c.WasmEdge_CallingFrameContext,
    in: [*c]const c.WasmEdge_Value,
    out: [*c]c.WasmEdge_Value,
) callconv(.C) c.WasmEdge_Result {
    const alloc: *const std.mem.Allocator = @alignCast(@ptrCast(data));

    const lower_addr = c.WasmEdge_ValueGetI32(in[0]);
    const upper_addr: u32 = @intCast(c.WasmEdge_ValueGetI32(in[1]));

    const memory = c.WasmEdge_CallingFrameGetMemoryInstance(frame, 0);

    const lower = c.cstr(c.WasmEdge_MemoryInstanceGetPointerConst(
        memory,
        @intCast(lower_addr),
        @sizeOf([*c]const u8),
    ));

    var upper_buf = alloc.*.alloc(u8, lower.len) catch return c.WasmEdge_Result_Fail;
    const upper = std.ascii.upperString(upper_buf, lower);

    {
        const res = c.WasmEdge_MemoryInstanceSetData(memory, upper.ptr, upper_addr, @intCast(upper.len));
        if (!c.WasmEdge_ResultOK(res)) {
            std.debug.panic("Could not run WASI main: {s}\n", .{c.WasmEdge_ResultGetMessage(res)});
        }
    }

    out.* = c.WasmEdge_ValueGenI32(@intCast(upper.len));

    return c.WasmEdge_Result_Success;
}

fn wasmExec(
    _: ?*anyopaque,
    _: ?*const c.WasmEdge_CallingFrameContext,
    _: [*c]const c.WasmEdge_Value,
    _: [*c]c.WasmEdge_Value,
) callconv(.C) c.WasmEdge_Result {
    // const allocator: std.mem.Allocator = @ptrCast(data).*;

    // const argv = c.WasmEdge_ValueGen

    // const result = std.os.ChildProcess.exec(
    //     allocator,
    //     argv,
    // ) catch return c.WasmEdge_Result_Fail;

    return c.WasmEdge_Result_Success;
}

test {
    _ = c;
}

// To support WASI main() and executing arbitrary functions:
// zig build-exe foo.zig -target wasm32-wasi -rdynamic
