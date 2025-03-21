//! This mirrors the structure of `Cizero.zig`
//! and hence does not always adhere to Zig's naming conventions.

const std = @import("std");

const utils = @import("utils");
const nix = utils.nix;

pub const components = struct {
    pub fn CallbackResult(comptime T: type) type {
        return union(enum) {
            /// The name of the error that occured
            /// trying to obtain a `T`.
            err: []const u8,
            ok: Ok,

            pub const Ok = T;
        };
    }

    pub const Nix = struct {
        pub const Job = struct {
            pub const Eval = struct {
                pub const Result = EvalResult;
            };

            pub const Build = struct {
                pub const Result = BuildResult;
            };
        };

        pub const EvalFormat = enum { nix, json, raw };

        pub const EvalResult = union(enum) {
            ok: []const u8,
            /// error message
            failed: []const u8,
            ifd_failed: nix.FailedBuilds,

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                switch (self.*) {
                    .ok => |evaluated| allocator.free(evaluated),
                    .failed => |msg| allocator.free(msg),
                    .ifd_failed => |*ifd_failed| ifd_failed.deinit(allocator),
                }
                self.* = undefined;
            }
        };

        pub const BuildResult = union(enum) {
            /// output paths produced
            outputs: []const []const u8,
            failed: nix.FailedBuilds,

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                switch (self.*) {
                    .outputs => |outputs| {
                        for (outputs) |output| allocator.free(output);
                        allocator.free(outputs);
                    },
                    .failed => |*failed| failed.deinit(allocator),
                }
                self.* = undefined;
            }
        };
    };
};
