const std = @import("std");

const Plugin = @import("Plugin.zig");

impl: *anyopaque,
impl_deinit: ?*const fn (*anyopaque) void,
impl_host_functions: *const fn (*anyopaque, std.mem.Allocator) std.mem.Allocator.Error!std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef),

name: []const u8,

pub fn deinit(self: *@This()) void {
    if (self.impl_deinit) |f| f(self.impl);
}

pub fn init(impl: anytype) @This() {
    const Impl = std.meta.Child(@TypeOf(impl));
    return .{
        .impl = impl,
        .impl_deinit = if (comptime std.meta.trait.hasFn("deinit")(Impl)) @ptrCast(&Impl.deinit) else null,
        .impl_host_functions = @ptrCast(&Impl.hostFunctions),
        .name = Impl.name,
    };
}

/// The returned map's keys are expected to live at least as long as `impl`.
/// Remember to deinit after use.
pub fn hostFunctions(self: @This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Plugin.Runtime.HostFunctionDef) {
    return self.impl_host_functions(self.impl, allocator);
}
