const std = @import("std");
const trait = @import("trait");

const Runtime = @import("Runtime.zig");

impl: *anyopaque,
impl_deinit: ?*const fn (*anyopaque) void,
impl_host_functions: *const fn (*anyopaque, std.mem.Allocator) std.mem.Allocator.Error!std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef),
impl_start: ?*const fn (*anyopaque) StartError!std.Thread,
impl_stop: ?*const fn (*anyopaque) void,

name: []const u8,

pub fn deinit(self: *@This()) void {
    if (self.impl_deinit) |f| f(self.impl);
}

pub fn init(impl: anytype) @This() {
    const Impl = std.meta.Child(@TypeOf(impl));
    return .{
        .impl = impl,
        .impl_deinit = if (comptime trait.hasFn("deinit")(Impl)) @ptrCast(&Impl.deinit) else null,
        .impl_host_functions = @ptrCast(&Impl.hostFunctions),
        .impl_start = if (comptime trait.hasFn("start")(Impl)) @ptrCast(&Impl.start) else null,
        .impl_stop = if (comptime trait.hasFn("stop")(Impl)) @ptrCast(&Impl.stop) else null,
        .name = Impl.name,
    };
}

/// The returned map's keys are expected to live at least as long as `impl`.
/// Remember to deinit after use.
pub fn hostFunctions(self: @This(), allocator: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(Runtime.HostFunctionDef) {
    return self.impl_host_functions(self.impl, allocator);
}

pub const StartError = std.Thread.SpawnError || std.Thread.SetNameError;

pub fn start(self: @This()) StartError!?std.Thread {
    return if (self.impl_start) |f| try f(self.impl) else null;
}

pub fn stop(self: @This()) void {
    if (self.impl_stop) |f| f(self.impl);
}
