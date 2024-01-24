const std = @import("std");
const trait = @import("trait");

const lib = @import("lib");
const wasm = lib.wasm;

const PluginRuntime = @import("Plugin.zig").Runtime;

pub const Http = @import("components/Http.zig");
pub const Nix = @import("components/Nix.zig");
pub const Process = @import("components/Process.zig");
pub const Timeout = @import("components/Timeout.zig");

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

            pub fn run(self: @This(), allocator: std.mem.Allocator, runtime: PluginRuntime, inputs: []const wasm.Value, outputs: []wasm.Value) !struct {
                success: bool,
                done: bool,
            } {
                const callback = self.callbackPtr();

                const success = try callback.run(allocator, runtime, inputs, outputs);

                const done = callback.done(success, outputs);
                if (done) self.remove(allocator);

                return .{
                    .success = success,
                    .done = done,
                };
            }

            pub fn remove(self: @This(), allocator: std.mem.Allocator) void {
                const plugin_callbacks = self.map_entry.value_ptr;
                var removed = plugin_callbacks.swapRemove(self.callback_idx);
                removed.deinit(allocator);
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
            for (callbacks.items) |*callback| callback.deinit(allocator);
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
                .{ "foo", "foo", "bar" },
                .{ "foo-1", "foo-2", "bar-1" },
            ) |plugin_name, func_name|
                try cbs.insert(std.testing.allocator, plugin_name, func_name, null, undefined);

            var iter = cbs.iterator();
            inline for (
                // Order is not guaranteed and may change without being a failure.
                .{ "bar", "foo", "foo" },
                .{ "bar-1", "foo-1", "foo-2" },
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
            user_data: ?[]const u8,
            condition: Condition,
        ) !void {
            const callbacks = blk: {
                const result = try self.map.getOrPut(allocator, plugin_name);
                if (!result.found_existing) result.value_ptr.* = .{};
                break :blk result.value_ptr;
            };

            try callbacks.append(allocator, try Callback.init(allocator, func_name, user_data, condition));
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
        user_data: ?[]const u8,
        condition: T,

        pub const Condition = T;

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (comptime trait.hasFn("deinit")(T)) self.condition.deinit(allocator);
            if (self.user_data) |user_data| allocator.free(user_data);
            allocator.free(self.func_name);
        }

        pub fn init(allocator: std.mem.Allocator, func_name: []const u8, user_data: ?[]const u8, condition: T) !@This() {
            const func_name_z = try allocator.dupeZ(u8, func_name);
            errdefer allocator.free(func_name_z);

            const user_data_dupe = if (user_data) |ud| try allocator.dupe(u8, ud) else null;
            errdefer if (user_data_dupe) |ud_dupe| allocator.free(ud_dupe);

            return .{
                .func_name = func_name_z,
                .user_data = user_data_dupe,
                .condition = condition,
            };
        }

        pub fn run(self: *const @This(), allocator: std.mem.Allocator, runtime: PluginRuntime, inputs: []const wasm.Value, outputs: []wasm.Value) !bool {
            const linear = try runtime.linearMemoryAllocator();
            const linear_allocator = linear.allocator();

            const user_data = if (self.user_data) |user_data| try linear_allocator.dupe(u8, user_data) else null;
            defer if (user_data) |ud| linear_allocator.free(ud);

            var final_inputs = try allocator.alloc(wasm.Value, inputs.len + 2);
            defer allocator.free(final_inputs);

            final_inputs[0] = .{ .i32 = if (user_data) |ud| @intCast(linear.memory.offset(ud.ptr)) else 0 };
            final_inputs[1] = .{ .i32 = if (user_data) |ud| @intCast(ud.len) else 0 };
            for (final_inputs[2..], inputs) |*final_input, input| final_input.* = input;

            // TODO run on new thread
            const success = try runtime.call(self.func_name, final_inputs, outputs);
            if (!success) std.log.info("callback function \"{s}\" from plugin \"{s}\" finished unsuccessfully", .{ self.func_name, runtime.plugin.name() });

            return success;
        }

        pub fn done(self: *const @This(), success: bool, outputs: []const wasm.Value) bool {
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

    pub fn check(self: @This(), success: bool, outputs: []const wasm.Value) bool {
        return switch (self) {
            .always => true,
            .on => |on| on.failure and !success or
                if (on.output0) |v| outputs[0].i32 == @intFromBool(v) else false,
        };
    }
};

pub fn rejectIfStopped(running: *const std.atomic.Value(bool)) error{ComponentStopped}!void {
    if (!running.load(.Monotonic)) return error.ComponentStopped;
}
