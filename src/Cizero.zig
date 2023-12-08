const std = @import("std");

const comps = @import("components.zig");
const meta = @import("meta.zig");

const Registry = @import("Registry.zig");

const Components = struct {
    http: *comps.Http,
    nix: comps.Nix,
    process: comps.Process,
    timeout: comps.Timeout,

    const fields = @typeInfo(@This()).Struct.fields;

    const InitError = blk: {
        var set = error{};
        inline for (fields) |field| {
            const T = meta.OptionalChild(field.type) orelse field.type;
            if (@hasDecl(T, "InitError")) set = set || T.InitError;
        }
        break :blk set;
    };

    fn register(self: *@This(), registry: *Registry) !void {
        inline for (fields) |field| {
            const value_ptr = &@field(self, field.name);
            try registry.registerComponent(if (comptime std.meta.trait.isSingleItemPtr(field.type)) value_ptr.* else value_ptr);
        }
    }
};

registry: Registry,
components: Components,

pub fn deinit(self: *@This()) void {
    self.registry.deinit();
    self.registry.allocator.destroy(self);
}

pub fn init(allocator: std.mem.Allocator) Components.InitError!*@This() {
    var self = try allocator.create(@This());

    var http = try comps.Http.init(allocator, &self.registry);
    errdefer http.deinit();

    var nix = try comps.Nix.init(allocator);
    errdefer nix.deinit();

    self.* = .{
        .registry = .{ .allocator = allocator },
        .components = .{
            .http = http,
            .nix = nix,
            .process = .{ .allocator = allocator },
            .timeout = .{ .allocator = allocator, .registry = &self.registry },
        },
    };
    try self.components.register(&self.registry);

    return self;
}

pub fn run(self: *@This()) !void {
    var threads_buf: [Components.fields.len]std.Thread = undefined;
    var threads: []const std.Thread = threads_buf[0..0];

    for (self.registry.components.items) |component|
        if (try component.start()) |thread| {
            threads_buf[threads.len] = thread;
            threads = threads_buf[0 .. threads.len + 1];
        };

    for (threads) |thread| thread.join();
}

pub fn stop(self: *@This()) void {
    for (self.registry.components.items) |component| component.stop();
}
