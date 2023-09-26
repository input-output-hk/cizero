const std = @import("std");

pub const Callback = struct {
    func_name: [:0]const u8,
    condition: Condition,

    pub const EventType = enum {
        timeout_ms,
    };

    pub const Condition = union(EventType) {
        timeout_ms: u64,
    };

    pub const Event = union(EventType) {
        timeout_ms,
    };

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.func_name);
    }

    fn init(allocator: std.mem.Allocator, func_name: []const u8, condition: Callback.Condition) !@This() {
        return .{
            .func_name = try allocator.dupeZ(u8, func_name),
            .condition = condition,
        };
    }
};

allocator: std.mem.Allocator,

callback: ?Callback = null,

kv: std.StringHashMap([]const u8),

pub fn deinit(self: *@This()) void {
    if (self.callback) |cb| self.allocator.free(cb.func_name);
    self.kv.deinit();
}

pub fn init(allocator: std.mem.Allocator) @This() {
    return .{
        .allocator = allocator,
        .kv = std.StringHashMap([]const u8).init(allocator),
    };
}

/// Copies `func_name`.
pub fn setCallback(self: *@This(), func_name: []const u8, condition: Callback.Condition) !void {
    if (self.callback != null) return error.PluginCannotYield;

    self.callback = try Callback.init(self.allocator, func_name, condition);
}

pub fn unsetCallback(self: *@This()) !void {
    if (self.callback == null) return error.PluginCannotContinue;

    if (self.callback) |cb| cb.deinit(self.allocator);
    self.callback = null;
}
