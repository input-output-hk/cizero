const std = @import("std");
const zqlite = @import("zqlite");

const c = @import("c.zig");

const log_scope = .sql;
const log = std.log.scoped(log_scope);

pub fn migrate(conn: zqlite.Conn) !void {
    if (blk: {
        const row = (try conn.row("PRAGMA user_version", .{})).?;
        defer row.deinit();

        break :blk row.int(0) == 0;
    }) {
        try conn.transaction();
        errdefer conn.rollback();

        try logErr(conn, conn.execNoArgs(@embedFile("sql/schema.sql")));
        try logErr(conn, conn.execNoArgs("PRAGMA user_version = 1"));

        try conn.commit();
    }
}

pub fn enableLogging(conn: zqlite.Conn) void {
    if (comptime !std.log.logEnabled(.debug, log_scope)) return;
    _ = c.sqlite3_trace_v2(@ptrCast(conn.conn), c.SQLITE_TRACE_STMT, traceStmt, null);
}

fn traceStmt(event: c_uint, ctx: ?*anyopaque, _: ?*anyopaque, x: ?*anyopaque) callconv(.C) c_int {
    std.debug.assert(event == c.SQLITE_TRACE_STMT);
    std.debug.assert(ctx == null);

    const sql: [*:0]const u8 = @ptrCast(x.?);
    log.debug("trace: {s}", .{sql});

    return 0;
}

pub const queries = struct {
    pub const plugins = struct {
        pub fn insert(conn: zqlite.Conn, name: []const u8, wasm: []const u8) !void {
            try logErr(conn, conn.exec(
                \\INSERT INTO "plugin" ("name", "wasm") VALUES (?, ?)
            , .{ name, zqlite.blob(wasm) }));
        }

        pub fn getWasm(allocator: std.mem.Allocator, conn: zqlite.Conn, name: []const u8) ![]const u8 {
            return if (try logErr(conn, conn.row(
                \\SELECT "wasm"
                \\FROM "plugin"
                \\WHERE "name" = ?
            , .{name}))) |row| blk: {
                defer row.deinit();
                break :blk allocator.dupe(u8, row.blob(0));
            } else error.NoSuchPlugin;
        }
    };
};

fn logErr(conn: zqlite.Conn, error_union: anytype) @TypeOf(error_union) {
    return if (error_union) |result| result else |err| blk: {
        log.err("{s}: {s}", .{ @errorName(err), conn.lastError() });
        break :blk err;
    };
}
