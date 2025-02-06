const std = @import("std");
const trait = @import("trait");
const zqlite = @import("zqlite");

const utils = @import("utils");
const meta = utils.meta;

pub const components = @import("components.zig");
pub const fs = @import("fs.zig");
pub const sql = @import("sql.zig");

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
            const T = meta.OptionalChild(field.type) orelse field.type;
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
wait_group: std.Thread.WaitGroup = .{},

pub fn deinit(self: *@This()) void {
    self.registry.deinit();
    self.db_pool.deinit();
    self.registry.allocator.destroy(self);
}

pub const Config = struct {
    db: Db,

    nix: components.Nix.Config = .{},

    pub const Db = meta.SubStruct(
        zqlite.Pool.Config,
        std.enums.EnumSet(std.meta.FieldEnum(zqlite.Pool.Config)).initMany(&.{ .path, .flags, .size }),
    );
};

pub fn init(allocator: std.mem.Allocator, config: Config) (error{DbInitError} || zqlite.Error || Components.InitError)!*@This() {
    var self = try allocator.create(@This());
    errdefer allocator.destroy(self);

    var http = try components.Http.init(allocator, &self.registry, &self.wait_group);
    errdefer http.deinit();

    var nix = try components.Nix.init(allocator, config.nix, &self.registry, &self.wait_group);
    errdefer nix.deinit();

    self.* = .{
        .db_pool = zqlite.Pool.init(allocator, .{
            .path = config.db.path,
            .flags = config.db.flags,
            .size = config.db.size,
            .on_connection = initDbConn,
        }) catch |err| {
            std.log.err("could not initialize database: {s}", .{@errorName(err)});
            return error.DbInitError;
        },
        .registry = .{ .allocator = allocator, .db_pool = &self.db_pool },
        .components = .{
            .http = http,
            .nix = nix,
            .process = .{ .allocator = allocator },
            .timeout = .{ .allocator = allocator, .registry = &self.registry, .wait_group = &self.wait_group },
        },
    };
    errdefer self.deinit();

    {
        const conn = self.db_pool.acquire();
        defer self.db_pool.release(conn);

        try sql.migrate(conn);
    }

    try self.components.register(&self.registry);

    return self;
}

fn initDbConn(conn: zqlite.Conn) !void {
    try conn.busyTimeout(std.time.ms_per_s);
    try sql.setJournalMode(conn, .WAL);
    try sql.enableForeignKeys(conn);
    sql.enableLogging(conn);
}

pub fn start(self: *@This()) !void {
    for (self.registry.components.items) |component| try component.start();
}

pub fn stop(self: *@This()) void {
    for (self.registry.components.items) |component| component.stop();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
