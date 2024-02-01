const std = @import("std");
const trait = @import("trait");
const zqlite = @import("zqlite");

const lib = @import("lib");

const sql = @import("sql.zig");

pub const components = @import("components.zig");

pub const Registry = @import("Registry.zig");
pub const Runtime = @import("Runtime.zig");

const Components = struct {
    http: *components.Http,
    nix: components.Nix,
    process: components.Process,
    timeout: components.Timeout,

    const fields = @typeInfo(@This()).Struct.fields;

    const InitError = blk: {
        var set = error{};
        for (fields) |field| {
            const T = lib.meta.OptionalChild(field.type) orelse field.type;
            if (@hasDecl(T, "InitError")) set = set || T.InitError;
        }
        break :blk set;
    };

    fn register(self: *@This(), registry: *Registry) !void {
        inline for (fields) |field| {
            const value_ptr = &@field(self, field.name);
            try registry.registerComponent(if (comptime trait.ptrOfSize(.One)(field.type)) value_ptr.* else value_ptr);
        }
    }
};

db_pool: zqlite.Pool,
registry: Registry,
components: Components,

pub fn deinit(self: *@This()) void {
    self.registry.deinit();
    self.db_pool.deinit();
    self.registry.allocator.destroy(self);
}

pub fn init(allocator: std.mem.Allocator) (error{DbError} || Components.InitError)!*@This() {
    var self = try allocator.create(@This());

    var http = try components.Http.init(allocator, &self.registry);
    errdefer http.deinit();

    var nix = try components.Nix.init(allocator, &self.registry);
    errdefer nix.deinit();

    self.* = .{
        .db_pool = zqlite.Pool.init(allocator, .{
            .path = ":memory:",

            // For some reason other connections do not see the new tables
            // if we run the migration in here.
            .on_first_connection = if (false) initDb else null,

            .on_connection = initDbConn,
        }) catch |err| @panic(@errorName(err)),
        .registry = .{ .allocator = allocator, .db_pool = &self.db_pool },
        .components = .{
            .http = http,
            .nix = nix,
            .process = .{ .allocator = allocator },
            .timeout = .{ .allocator = allocator, .registry = &self.registry },
        },
    };
    errdefer self.deinit();

    {
        const conn = self.db_pool.acquire();
        defer self.db_pool.release(conn);

        initDb(conn) catch return error.DbError;
    }

    try self.components.register(&self.registry);

    return self;
}

fn initDb(conn: zqlite.Conn) !void {
    try sql.migrate(conn);
}

fn initDbConn(conn: zqlite.Conn) !void {
    try conn.busyTimeout(std.time.ms_per_s);
    try sql.enableForeignKeys(conn);
    sql.enableLogging(conn);
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

test {
    std.testing.refAllDeclsRecursive(@This());
}
