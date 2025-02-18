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

fn utilsNixOptionsRunFn(args: utils.nix.Options.RunFnArgs) @typeInfo(@TypeOf(std.process.Child.run)).Fn.return_type.? {
    return @This().process.exec(.{
        .allocator = args.allocator,
        .max_output_bytes = args.max_output_bytes,
        .argv = args.argv,
    });
}

pub const user_data = @import("abi.zig").CallbackData.user_data;

pub usingnamespace @import("components.zig");

export fn cizero_mem_alloc(len: usize, ptr_align: u8) ?[*]u8 {
    return std.heap.wasm_allocator.rawAlloc(len, ptr_align, 0);
}

export fn cizero_mem_resize(buf: [*]u8, buf_len: usize, buf_align: u8, new_len: usize) bool {
    return std.heap.wasm_allocator.rawResize(buf[0..buf_len], buf_align, new_len, 0);
}

export fn cizero_mem_free(buf: [*]u8, buf_len: usize, buf_align: u8) void {
    std.heap.wasm_allocator.rawFree(buf[0..buf_len], buf_align, 0);
}
