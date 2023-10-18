const std = @import("std");

const wasm = @import("wasm.zig");

const Registry = @import("Registry.zig");

pub const Process = @import("modules/Process.zig");
pub const Timeout = @import("modules/Timeout.zig");
pub const ToUpper = @import("modules/ToUpper.zig");

pub fn CallbacksUnmanaged(comptime Condition: type) type {
    return struct {
        const Self = @This();

        pub const Callback = CallbackUnmanaged(Condition);

        pub const Map = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Callback));

        pub const Entry = struct {
            callbacks: *Self,
            map_entry: Map.Entry,
            callback_idx: usize,

            pub fn pluginName(self: @This()) []const u8 {
                return self.map_entry.key_ptr.*;
            }

            pub fn callbackPtr(self: @This()) *Callback {
                return &self.map_entry.value_ptr.items[self.callback_idx];
            }

            fn valid(self: @This()) bool {
                return self.callback_idx < self.map_entry.value_ptr.items.len;
            }

            pub fn run(self: @This(), allocator: std.mem.Allocator, registry: Registry, inputs: []const wasm.Val, outputs: []wasm.Val) !void {
                const plugin_name = self.pluginName();
                const callback = self.callbackPtr();

                const runtime = try registry.runtime(plugin_name);

                // TODO run on new thread
                const success = try runtime.call(callback.func_name, inputs, outputs);
                if (!success) std.log.info("callback function \"{s}\" from plugin \"{s}\" finished unsuccessfully", .{ callback.func_name, plugin_name });

                if (callback.done(success, outputs)) self.remove(allocator);
            }

            pub fn remove(self: @This(), allocator: std.mem.Allocator) void {
                const plugin_callbacks = self.map_entry.value_ptr;
                plugin_callbacks.swapRemove(self.callback_idx).deinit(allocator);
                if (plugin_callbacks.items.len == 0) {
                    deallocateCallbacks(allocator, plugin_callbacks);
                    self.callbacks.map.removeByPtr(self.map_entry.key_ptr);
                }
            }
        };

        /// Calling `Entry.remove()` during iteration is not supported.
        pub const Iterator = struct {
            callbacks: *Self,
            map_iter: Map.Iterator,
            prev: ?Entry = null,

            pub fn next(self: *@This()) ?Entry {
                var curr: ?Entry = null;

                if (self.prev) |*prev| {
                    prev.callback_idx += 1;
                    if (prev.valid()) curr = prev.*;
                }

                if (curr == null) {
                    if (self.map_iter.next()) |map_entry| {
                        curr = .{
                            .callbacks = self.callbacks,
                            .map_entry = map_entry,
                            .callback_idx = 0,
                        };
                        std.debug.assert(curr.?.valid());
                    }
                }

                self.prev = curr;

                return curr;
            }
        };

        map: Map = .{},

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            {
                var callbacks_iter = self.map.valueIterator();
                while (callbacks_iter.next()) |callbacks| deallocateCallbacks(allocator, callbacks);
            }

            self.map.deinit(allocator);
        }

        fn deallocateCallbacks(allocator: std.mem.Allocator, callbacks: *std.ArrayListUnmanaged(Callback)) void {
            for (callbacks.items) |callback| callback.deinit(allocator);
            callbacks.deinit(allocator);
        }

        pub fn iterator(self: *@This()) Iterator {
            return .{
                .callbacks = self,
                .map_iter = self.map.iterator(),
            };
        }

        test iterator {
            var cbs = @This(){};
            defer cbs.deinit(std.testing.allocator);

            inline for (
                &.{"foo", "foo", "bar"},
                &.{"foo-1", "foo-2", "bar-1"},
            ) |plugin_name, func_name|
                try cbs.insert(std.testing.allocator, plugin_name, func_name, .{});

            var iter = cbs.iterator();
            inline for (
                // Order is not guaranteed and may change without being a failure.
                &.{ "bar", "foo", "foo" },
                &.{ "bar-1", "foo-1", "foo-2" },
            ) |plugin_name, func_name| {
                const entry = iter.next().?;
                try std.testing.expectEqualStrings(plugin_name, entry.pluginName());
                try std.testing.expectEqualStrings(func_name, entry.callbackPtr().func_name);
            }
            inline for (0..2) |_| try std.testing.expectEqual(@as(?@This().Entry, null), iter.next());
        }

        pub fn insert(
            self: *@This(),
            allocator: std.mem.Allocator,
            plugin_name: []const u8,
            func_name: []const u8,
            condition: Condition,
        ) !void {
            const callbacks = blk: {
                const result = try self.map.getOrPut(allocator, plugin_name);
                if (!result.found_existing) result.value_ptr.* = .{};
                break :blk result.value_ptr;
            };

            try callbacks.append(allocator, try Callback.init(allocator, func_name, condition));
        }
    };
}

test CallbacksUnmanaged {
    _ = CallbacksUnmanaged(struct {
        pub fn done(_: @This()) CallbackDoneCondition {
            return .always;
        }
    });
}

pub fn CallbackUnmanaged(comptime T: type) type {
    return struct {
        func_name: [:0]const u8,
        condition: T,

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.func_name);
        }

        pub fn init(allocator: std.mem.Allocator, func_name: []const u8, condition: T) !@This() {
            return .{
                .func_name = try allocator.dupeZ(u8, func_name),
                .condition = condition,
            };
        }

        pub fn done(self: @This(), success: bool, outputs: []const wasm.Val) bool {
            const condition: CallbackDoneCondition = self.condition.done();
            return condition.check(success, outputs);
        }
    };
}

pub const CallbackDoneCondition = union(enum) {
    always,
    on: struct {
        failure: bool = true,
        output0: ?bool = true,
    },

    pub fn check(self: @This(), success: bool, outputs: []const wasm.Val) bool {
        return switch (self) {
            .always => true,
            .on => |on|
                on.failure and !success or
                if (on.output0) |v| outputs[0].i32 == @intFromBool(v) else false,
        };
    }
};

pub fn stringArrayHashMapUnmanagedFromStruct(comptime T: type, allocator: std.mem.Allocator, strukt: anytype) !std.StringArrayHashMapUnmanaged(T) {
    var map = std.StringArrayHashMapUnmanaged(T){};
    errdefer map.deinit(allocator);

    const fields = @typeInfo(@TypeOf(strukt)).Struct.fields;
    try map.ensureTotalCapacity(allocator, fields.len);
    inline for (fields) |field|
        map.putAssumeCapacityNoClobber(field.name, @field(strukt, field.name));

    return map;
}

test {
    _ = std.testing.refAllDecls(@This());
}
