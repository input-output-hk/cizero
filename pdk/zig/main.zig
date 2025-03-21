const root = @import("root");
const builtin = @import("builtin");
const std = @import("std");
const utils = @import("utils");

comptime {
    if (root != @This() and
        !@hasDecl(root, "utils_nix_options") and
        !builtin.is_test) @compileError(
        \\The nix utils options are not configured so compilation will fail.
        \\
        \\Unfortunately I cannot do this for you.
        \\Please set them in your root source file, for example like this:
        \\
        \\
    ++ "\t" ++
        \\pub const utils_nix_options = @import("cizero-pdk").utils_nix_options;
    );
}

pub const utils_nix_options = utils.nix.Options{
    .log_scope = .nix,
    .runFn = utilsNixOptionsRunFn,
};

fn utilsNixOptionsRunFn(args: utils.nix.Options.RunFnArgs) @typeInfo(@TypeOf(std.process.Child.run)).@"fn".return_type.? {
    return @This().process.exec(.{
        .allocator = args.allocator,
        .max_output_bytes = args.max_output_bytes,
        .argv = args.argv,
    });
}

pub const user_data = @import("abi.zig").CallbackData.user_data_types;

pub usingnamespace @import("components.zig");

const Alignment = utils.meta.EnsurePowBits(std.meta.Tag(std.mem.Alignment), 0);

export fn cizero_mem_alloc(len: usize, alignment: Alignment) ?[*]u8 {
    return std.heap.wasm_allocator.rawAlloc(len, @enumFromInt(alignment), 0);
}

export fn cizero_mem_resize(memory: [*]u8, memory_len: usize, alignment: Alignment, new_len: usize) bool {
    return std.heap.wasm_allocator.rawResize(memory[0..memory_len], @enumFromInt(alignment), new_len, 0);
}

export fn cizero_mem_remap(memory: [*]u8, memory_len: usize, alignment: Alignment, new_len: usize) ?[*]u8 {
    return std.heap.wasm_allocator.rawRemap(memory[0..memory_len], @enumFromInt(alignment), new_len, 0);
}

export fn cizero_mem_free(memory: [*]u8, memory_len: usize, alignment: Alignment) void {
    std.heap.wasm_allocator.rawFree(memory[0..memory_len], @enumFromInt(alignment), 0);
}
