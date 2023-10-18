const std = @import("std");

const c = @import("c.zig");
const wasm = @import("wasm.zig");

pub fn fromVal(v: *const c.wasmtime_val) !wasm.Value {
    return switch (v.kind) {
        c.WASMTIME_I32 => .{ .val = .{ .i32 = v.of.i32 } },
        c.WASMTIME_I64 => .{ .val = .{ .i64 = v.of.i64 } },
        c.WASMTIME_F32 => .{ .val = .{ .f32 = v.of.f32 } },
        c.WASMTIME_F64 => .{ .val = .{ .f64 = v.of.f64 } },
        c.WASMTIME_V128 => .{ .val = .{ .v128 = v.of.v128 } },
        c.WASMTIME_FUNCREF => .{ .ref = .{ .funcref = @ptrCast(&v.of.funcref) } },
        c.WASMTIME_EXTERNREF => .{ .ref = .{ .externref = @ptrCast(&v.of.externref) } },
        else => error.UnknownWasmtimeVal,
    };
}

pub fn val(value: wasm.Value) c.wasmtime_val {
    return .{
        .kind = valkind(value.valueType()),
        .of = switch (value) {
            .val => |val_| switch (val_) {
                .i32 => |v| .{ .i32 = v },
                .i64 => |v| .{ .i64 = v },
                .f32 => |v| .{ .f32 = v },
                .f64 => |v| .{ .f64 = v },
                .v128 => |v| .{ .v128 = v },
            },
            .ref => |ref| switch (ref) {
                .funcref => |r| .{ .funcref = @as(*const c.wasmtime_func_t, @alignCast(@ptrCast(r))).* },
                .externref => |r| .{ .externref = c.wasmtime_externref_new(@constCast(r), null) }, // XXX Is this destroyed when the c.wasmtime_val is destroyed?
            },
        },
    };
}

pub fn valkind(kind: wasm.ValueType) c.wasmtime_valkind_t {
    return switch (kind) {
        .val => |val_kind| switch (val_kind) {
            .i32 => c.WASMTIME_I32,
            .i64 => c.WASMTIME_I64,
            .f32 => c.WASMTIME_F32,
            .f64 => c.WASMTIME_F64,
            .v128 => c.WASMTIME_V128,
        },
        .ref => |ref_kind| switch (ref_kind) {
            .funcref => c.WASMTIME_FUNCREF,
            .externref => c.WASMTIME_EXTERNREF,
        },
    };
}

pub fn valtypeVec(allocator: std.mem.Allocator, valtypes: []const wasm.ValueType) !c.wasm_valtype_vec_t {
    var wasm_valtypes = try allocator.alloc(*c.wasm_valtype_t, valtypes.len);
    defer allocator.free(wasm_valtypes);

    for (valtypes, 0..) |in, i| wasm_valtypes[i] = c.wasm_valtype_new(valkind(in)).?;

    var vec: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&vec, wasm_valtypes.len, wasm_valtypes.ptr);

    return vec;
}

pub fn functype(allocator: std.mem.Allocator, signature: wasm.Type) !*c.wasm_functype_t {
    var params = try valtypeVec(allocator, signature.params);
    var returns = try valtypeVec(allocator, signature.returns);
    return c.wasm_functype_new(&params, &returns).?;
}
