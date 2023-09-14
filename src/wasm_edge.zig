const std = @import("std");

const c = @import("c.zig");

pub const FunctionInstance = struct {
    func_type: ?*c.WasmEdge_FunctionTypeContext,
    func_inst: ?*c.WasmEdge_FunctionInstanceContext,

    pub fn deinit(self: *@This()) void {
        c.WasmEdge_FunctionTypeDelete(self.func_type);
    }

    pub fn init(
        params: []const c.WasmEdge_ValType,
        returns: []const c.WasmEdge_ValType,
        host_func: c.WasmEdge_HostFunc_t,
        data: ?*anyopaque,
        cost: u64,
    ) @This() {
        const func_type = c.WasmEdge_FunctionTypeCreate(
            @ptrCast(params), @intCast(params.len),
            @ptrCast(returns), @intCast(returns.len),
        );
        return .{
            .func_type = func_type,
            .func_inst = c.WasmEdge_FunctionInstanceCreate(func_type, host_func, data, cost),
        };
    }
};

pub const ModuleInstance = struct {
    mod_inst: ?*c.WasmEdge_ModuleInstanceContext,

    pub fn deinit(self: *@This()) void {
        c.WasmEdge_ModuleInstanceDelete(self.mod_inst);
    }

    pub fn init(name: [:0]const u8) @This() {
        const mod_name = c.WasmEdge_StringCreateByCString(name);
        defer c.WasmEdge_StringDelete(mod_name);
        return .{.mod_inst = c.WasmEdge_ModuleInstanceCreate(mod_name)};
    }

    pub fn addFunction(self: *@This(), name: [:0]const u8, func_inst: ?*c.WasmEdge_FunctionInstanceContext) void {
        const func_name = c.WasmEdge_StringCreateByCString(name);
        defer c.WasmEdge_StringDelete(func_name);
        c.WasmEdge_ModuleInstanceAddFunction(self.mod_inst, func_name, func_inst);
    }
};
