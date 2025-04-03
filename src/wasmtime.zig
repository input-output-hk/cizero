const std = @import("std");

const utils = @import("utils");
const wasm = utils.wasm;

const c = @import("c.zig");

pub fn fromVal(v: *const c.wasmtime_val) !wasm.Value {
    return switch (v.kind) {
        c.WASMTIME_I32 => .{ .i32 = v.of.i32 },
        c.WASMTIME_I64 => .{ .i64 = v.of.i64 },
        c.WASMTIME_F32 => .{ .f32 = v.of.f32 },
        c.WASMTIME_F64 => .{ .f64 = v.of.f64 },
        c.WASMTIME_V128 => .{ .v128 = v.of.v128 },
        c.WASMTIME_FUNCREF => .{ .funcref = @ptrCast(&v.of.funcref) },
        c.WASMTIME_EXTERNREF => .{ .externref = @ptrCast(&v.of.externref) },
        c.WASMTIME_ANYREF => error.UnknownWasmtimeVal,
        else => error.UnknownWasmtimeVal,
    };
}

pub fn val(value: wasm.Value) c.wasmtime_val {
    return .{
        .kind = valkind(value),
        .of = switch (value) {
            .i32 => |v| .{ .i32 = v },
            .i64 => |v| .{ .i64 = v },
            .f32 => |v| .{ .f32 = v },
            .f64 => |v| .{ .f64 = v },
            .v128 => |v| .{ .v128 = v },
            .funcref => |v| .{ .funcref = @as(*const c.wasmtime_func_t, @alignCast(@ptrCast(v))).* },
            .externref => |v| .{ .externref = @as(*const c.wasmtime_externref_t, @alignCast(@ptrCast(v))).* },
        },
    };
}

pub fn valkind(kind: wasm.Value.Type) c.wasmtime_valkind_t {
    return switch (kind) {
        .i32 => c.WASMTIME_I32,
        .i64 => c.WASMTIME_I64,
        .f32 => c.WASMTIME_F32,
        .f64 => c.WASMTIME_F64,
        .v128 => c.WASMTIME_V128,
        .funcref => c.WASMTIME_FUNCREF,
        .externref => c.WASMTIME_EXTERNREF,
    };
}

pub fn valtypeVec(allocator: std.mem.Allocator, valtypes: []const wasm.Value.Type) !c.wasm_valtype_vec_t {
    const wasm_valtypes = try allocator.alloc(*c.wasm_valtype_t, valtypes.len);
    defer allocator.free(wasm_valtypes);

    for (wasm_valtypes, valtypes) |*wasm_valtype, valtype| wasm_valtype.* = c.wasm_valtype_new(valkind(valtype)).?;

    var vec: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&vec, wasm_valtypes.len, wasm_valtypes.ptr);

    return vec;
}

pub fn functype(allocator: std.mem.Allocator, signature: wasm.Type) !*c.wasm_functype_t {
    var params = try valtypeVec(allocator, signature.params);
    errdefer c.wasm_valtype_vec_delete(&params);

    var returns = try valtypeVec(allocator, signature.returns);
    errdefer c.wasm_valtype_vec_delete(&returns);

    return c.wasm_functype_new(&params, &returns).?;
}
