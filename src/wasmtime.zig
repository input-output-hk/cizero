const std = @import("std");

const c = @import("c.zig");
const wasm = @import("wasm.zig");

pub fn fromVal(v: c.wasmtime_val) !wasm.Val {
    return switch (v.kind) {
        c.WASMTIME_I32 => .{ .i32 = v.of.i32 },
        c.WASMTIME_I64 => .{ .i64 = v.of.i64 },
        c.WASMTIME_F32 => .{ .f32 = v.of.f32 },
        c.WASMTIME_F64 => .{ .f64 = v.of.f64 },
        c.WASMTIME_V128 => .{ .v128 = v.of.v128 },
        else => error.UnknownWasmtimeVal,
    };
}

pub fn val(v: wasm.Val) c.wasmtime_val {
    return .{
        .kind = valkind(std.meta.activeTag(v)),
        .of = switch (v) {
            .i32 => |n| .{ .i32 = n },
            .i64 => |n| .{ .i64 = n },
            .f32 => |n| .{ .f32 = n },
            .f64 => |n| .{ .f64 = n },
            .v128 => |n| .{ .v128 = n },
        },
    };
}

pub fn valkind(kind: std.wasm.Valtype) c.wasm_valkind_t {
    return switch (kind) {
        .i32 => c.WASM_I32,
        .i64 => c.WASM_I64,
        .f32 => c.WASM_F32,
        .f64 => c.WASM_F64,
        .v128 => @panic("not supported"),
    };
}

pub fn valtypeVec(allocator: std.mem.Allocator, valtypes: []const std.wasm.Valtype) !c.wasm_valtype_vec_t {
    var wasm_valtypes = try allocator.alloc(*c.wasm_valtype_t, valtypes.len);
    defer allocator.free(wasm_valtypes);

    for (valtypes, 0..) |in, i| wasm_valtypes[i] = c.wasm_valtype_new(valkind(in)).?;

    var vec: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&vec, wasm_valtypes.len, wasm_valtypes.ptr);

    return vec;
}

pub fn functype(allocator: std.mem.Allocator, signature: std.wasm.Type) !*c.wasm_functype_t {
    var params = try valtypeVec(allocator, signature.params);
    var returns = try valtypeVec(allocator, signature.returns);
    return c.wasm_functype_new(&params, &returns).?;
}
