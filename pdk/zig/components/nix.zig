const std = @import("std");

const lib = @import("lib");
const mem = lib.mem;
const meta = lib.meta;

const abi = @import("../abi.zig");

const process = @import("process.zig");

const log_scope = .nix;
const log = std.log.scoped(log_scope);

const externs = struct {
    extern "cizero" fn nix_on_build(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
        installable: [*:0]const u8,
    ) void;

    const NixEvalFormat = enum(u8) { nix, json, raw };

    extern "cizero" fn nix_on_eval(
        func_name: [*:0]const u8,
        user_data_ptr: ?*const anyopaque,
        user_data_len: usize,
        expression: [*:0]const u8,
        format: NixEvalFormat,
    ) void;
};

pub fn onBuild(callback_func_name: [:0]const u8, user_data: anytype, installable: [:0]const u8) !void {
    const user_data_bytes = abi.fixZeroLenSlice(u8, mem.anyAsBytesUnpad(user_data));
    externs.nix_on_build(callback_func_name, user_data_bytes.ptr, user_data_bytes.len, installable);
}

pub const EvalFormat = externs.NixEvalFormat;

pub fn onEval(callback_func_name: [:0]const u8, user_data: anytype, expression: [:0]const u8, format: externs.NixEvalFormat) !void {
    const user_data_bytes = abi.fixZeroLenSlice(u8, mem.anyAsBytesUnpad(user_data));
    externs.nix_on_eval(callback_func_name, user_data_bytes.ptr, user_data_bytes.len, expression, format);
}

/// Output of `nix flake metadata --json`.
pub const FlakeMetadata = struct {
    description: ?[]const u8 = null,
    lastModified: i64,
    locked: LockedSource,
    locks: Locks,
    original: Source,
    originalUrl: []const u8,
    path: []const u8,
    resolved: Source,
    resolvedUrl: []const u8,
    revision: []const u8,

    /// As of Nix 2.20, the manual says
    /// the key should be called `lockedUrl`,
    /// but it is actually called just `url`.
    url: []const u8,

    // XXX make union(enum) by type
    pub const LockedSource = struct {
        lastModified: i64,
        narHash: []const u8,
        revCount: ?u64 = null,

        // XXX These are currently the same as in `Source`
        // but this will change once we make this a tagged union
        // because we can then enforce some types to be locked
        // (for example, git must have a `rev`).
        type: []const u8,
        url: ?[]const u8 = null,
        dir: ?[]const u8 = null,
        owner: ?[]const u8 = null,
        repo: ?[]const u8 = null,
        ref: ?[]const u8 = null,
        rev: ?[]const u8 = null,
        submodules: ?bool = null,
    };

    // XXX make union(enum) by type
    pub const Source = struct {
        type: []const u8,
        url: ?[]const u8 = null,
        dir: ?[]const u8 = null,
        owner: ?[]const u8 = null,
        repo: ?[]const u8 = null,
        ref: ?[]const u8 = null,
        rev: ?[]const u8 = null,
        submodules: ?bool = null,
    };

    /// Contents of `flake.lock`.
    pub const Locks = struct {
        root: []const u8,
        version: u8,
        nodes: std.json.ArrayHashMap(Node),

        pub const Node = union(enum) {
            root: Root,
            full: Full,
            leaf: Leaf,
            non_flake: NonFlake,

            pub const Full = struct {
                inputs: std.json.ArrayHashMap([]const []const u8),
                locked: LockedSource,
                original: Source,
            };

            pub const Leaf = meta.SubStruct(Full, &.{ .locked, .original });

            pub const Root = meta.SubStruct(Full, &.{.inputs});

            pub const NonFlake = struct {
                flake: bool = false,
                locked: LockedSource,
                original: Source,
            };

            pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
                if (source != .object) return error.UnexpectedToken;

                if (source.object.get("flake")) |flake| if (flake == .bool and !flake.bool) return .{ .non_flake = try std.json.parseFromValueLeaky(NonFlake, allocator, source, options) };

                const inputs = if (source.object.get("inputs")) |inputs| inputs: {
                    var map = std.StringArrayHashMapUnmanaged([]const []const u8){};
                    errdefer map.deinit(allocator);

                    var iter = inputs.object.iterator();
                    while (iter.next()) |input| try map.put(allocator, input.key_ptr.*, switch (input.value_ptr.*) {
                        .string => |string| &.{string},
                        .array => try std.json.parseFromValueLeaky([]const []const u8, allocator, input.value_ptr.*, options),
                        else => return error.UnexpectedToken,
                    });

                    break :inputs std.json.ArrayHashMap([]const []const u8){ .map = map };
                } else null;
                const locked = if (source.object.get("locked")) |locked| try std.json.parseFromValueLeaky(LockedSource, allocator, locked, options) else null;
                const original = if (source.object.get("original")) |original| try std.json.parseFromValueLeaky(Source, allocator, original, options) else null;

                return if (inputs != null and locked != null and original != null) .{ .full = .{
                    .inputs = inputs.?,
                    .locked = locked.?,
                    .original = original.?,
                } } else if (inputs == null and locked != null and original != null) .{ .leaf = .{
                    .locked = locked.?,
                    .original = original.?,
                } } else if (inputs != null and locked == null and original == null) .{ .root = .{
                    .inputs = inputs.?,
                } } else if (inputs == null and locked == null and original == null) .{ .root = .{
                    .inputs = std.json.ArrayHashMap([]const []const u8){ .map = .{} },
                } } else error.MissingField;
            }
        };
    };
};

pub const FlakeMetadataOptions = struct {
    max_output_bytes: usize = 50 * 1024,
    refresh: bool = true,
    no_write_lock_file: bool = true,
};

pub fn flakeMetadata(allocator: std.mem.Allocator, flake: []const u8, opts: FlakeMetadataOptions) !std.json.Parsed(FlakeMetadata) {
    const argv = try std.mem.concat(allocator, []const u8, &.{
        &.{
            "nix",
            "flake",
            "metadata",
        },
        if (opts.refresh) &.{"--refresh"} else &.{},
        if (opts.no_write_lock_file) &.{"--no-write-lock-file"} else &.{},
        &.{
            "--json",
            flake,
        },
    });
    defer allocator.free(argv);

    const result = try process.exec(.{
        .allocator = allocator,
        .max_output_bytes = opts.max_output_bytes,
        .argv = argv,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term != .Exited or result.term.Exited != 0) {
        log.debug("could not get flake metadata {s}: {}\n{s}", .{ flake, result.term, result.stderr });
        return error.FlakeMetadataFailed; // TODO return more specific error
    }

    const json_options = .{ .ignore_unknown_fields = true };

    const json = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, json_options);
    defer json.deinit();

    return std.json.parseFromValue(FlakeMetadata, allocator, json.value, json_options);
}

pub fn lockFlakeRef(allocator: std.mem.Allocator, flake_ref: []const u8, opts: FlakeMetadataOptions) ![]const u8 {
    const flake = std.mem.sliceTo(flake_ref, '#');

    const metadata = try flakeMetadata(allocator, flake, opts);
    defer metadata.deinit();

    const flake_ref_locked = try std.mem.concat(allocator, u8, &.{
        metadata.value.url,
        flake_ref[flake.len..],
    });
    errdefer allocator.free(flake_ref_locked);

    if (comptime std.log.logEnabled(.debug, log_scope)) {
        if (std.mem.eql(u8, flake_ref_locked, flake_ref))
            log.debug("flake reference {s} is already locked", .{flake_ref})
        else
            log.debug("flake reference {s} locked to {s}", .{ flake_ref, flake_ref_locked });
    }

    return flake_ref_locked;
}

test lockFlakeRef {
    // this test only works when run on cizero
    if (true) return error.SkipZigTest;

    const latest = "github:NixOS/nixpkgs";
    const input = latest ++ "/23.11";
    const expected = latest ++ "/057f9aecfb71c4437d2b27d3323df7f93c010b7e";

    {
        const locked = try lockFlakeRef(std.testing.allocator, input, .{});
        defer std.testing.allocator.free(locked);

        try std.testing.expectEqualStrings(expected, locked);
    }

    {
        const locked = try lockFlakeRef(std.testing.allocator, input ++ "#hello^out", .{});
        defer std.testing.allocator.free(locked);

        try std.testing.expectEqualStrings(expected ++ "#hello^out", locked);
    }
}
