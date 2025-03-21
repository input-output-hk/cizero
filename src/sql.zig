const std = @import("std");
const zqlite = @import("zqlite");
const zqlite_typed = @import("zqlite-typed");

const utils = @import("utils");
const fmt = utils.fmt;
const mem = utils.mem;
const meta = utils.meta;

const Query = zqlite_typed.Query;
const Exec = zqlite_typed.Exec;
const SimpleInsert = zqlite_typed.SimpleInsert;
const MergedTables = zqlite_typed.MergedTables;
const columnList = zqlite_typed.columnList;

const c = @import("c.zig");

pub fn migrate(conn: zqlite.Conn) !void {
    if (blk: {
        const row = (try conn.row("PRAGMA user_version", .{})).?;
        errdefer row.deinit();

        const user_version = row.int(0);

        try row.deinitErr();

        break :blk user_version == 0;
    }) {
        try conn.transaction();
        errdefer conn.rollback();

        {
            const sql = @embedFile("sql/schema.sql");
            try zqlite_typed.logErr(conn, .execNoArgs, .{sql});
        }
        {
            const sql = "PRAGMA user_version = 1";
            try zqlite_typed.logErr(conn, .execNoArgs, .{sql});
        }

        try conn.commit();
    }
}

pub fn setJournalMode(conn: zqlite.Conn, comptime mode: enum {
    DELETE,
    TRUNCATE,
    PERSIST,
    MEMORY,
    WAL,
    OFF,
}) !void {
    const sql = "PRAGMA journal_mode = " ++ @tagName(mode);
    try zqlite_typed.logErr(conn, .execNoArgs, .{sql});
}

pub fn enableForeignKeys(conn: zqlite.Conn) !void {
    const sql = "PRAGMA foreign_keys = ON";
    try zqlite_typed.logErr(conn, .execNoArgs, .{sql});
}

pub fn enableLogging(conn: zqlite.Conn) void {
    if (comptime !std.log.logEnabled(.debug, zqlite_typed.options.log_scope)) return;
    _ = c.sqlite3_trace_v2(@ptrCast(conn.conn), c.SQLITE_TRACE_STMT, traceStmt, null);
}

fn traceStmt(event: c_uint, ctx: ?*anyopaque, _: ?*anyopaque, x: ?*anyopaque) callconv(.C) c_int {
    std.debug.assert(event == c.SQLITE_TRACE_STMT);
    std.debug.assert(ctx == null);

    const sql: [*:0]const u8 = @ptrCast(x.?);
    zqlite_typed.log.debug("trace: {s}", .{fmt.fmtOneline(std.mem.span(sql))});

    return 0;
}

pub const queries = struct {
    pub const Plugin = struct {
        name: []const u8,
        wasm: zqlite.Blob,

        const table = "plugin";

        pub const Column = std.meta.FieldEnum(@This());

        pub const insert = SimpleInsert(table, @This());

        pub fn SelectByName(comptime columns: []const Column) type {
            return Query(
                \\SELECT
            ++ " " ++ columnList(table, columns) ++
                \\
                \\FROM "
            ++ table ++
                \\"
                \\WHERE "
            ++ @tagName(Column.name) ++
                \\" = ?
            ,
                false,
                meta.SubStruct(@This(), std.enums.EnumSet(Column).initMany(columns)),
                struct { []const u8 },
            );
        }
    };

    pub const Callback = struct {
        id: i64,
        plugin: []const u8,
        function: []const u8,
        user_data: ?zqlite.Blob,

        const table = "callback";

        pub const Column = std.meta.FieldEnum(@This());

        pub const insert = SimpleInsert(
            table,
            meta.SubStruct(@This(), std.enums.EnumSet(Column).initMany(&.{ .plugin, .function, .user_data })),
        );

        pub fn SelectById(comptime columns: []const Column) type {
            return Query(
                \\SELECT
            ++ " " ++ columnList(table, columns) ++
                \\
                \\FROM "
            ++ table ++
                \\"
                \\WHERE "rowid" = ?
            ,
                false,
                meta.SubStruct(@This(), columns),
                struct { i64 },
            );
        }

        pub const deleteById = Exec(
            \\DELETE FROM "
        ++ table ++
            \\"
            \\WHERE "
        ++ @tagName(Column.id) ++
            \\" = ?
        , struct { i64 });
    };

    pub const TimeoutCallback = struct {
        callback: i64,
        timestamp: i64,
        cron: ?[]const u8,

        const table = "timeout_callback";

        pub const Column = std.meta.FieldEnum(@This());

        pub const insert = SimpleInsert(table, @This());

        pub fn SelectNext(comptime columns: []const Column, comptime callback_columns: []const Callback.Column) type {
            return Query(
                \\SELECT
            ++ " " ++ mem.comptimeJoin(&.{
                columnList(table, columns),
                columnList(Callback.table, callback_columns),
            }, ", ") ++
                \\
                \\FROM "
            ++ Callback.table ++
                \\"
                \\INNER JOIN "
            ++ table ++
                \\" ON "
            ++ table ++
                \\"."
            ++ @tagName(Column.callback) ++
                \\" = "
            ++ Callback.table ++
                \\"."
            ++ @tagName(Callback.Column.id) ++
                \\"
                \\ORDER BY "
            ++ @tagName(Column.timestamp) ++
                \\" ASC
                \\LIMIT 1
            ,
                false,
                MergedTables(
                    null,
                    meta.SubStruct(@This(), std.enums.EnumSet(Column).initMany(columns)),
                    Callback.table,
                    meta.SubStruct(Callback, std.enums.EnumSet(Callback.Column).initMany(callback_columns)),
                ),
                @TypeOf(.{}),
            );
        }

        pub const updateTimestamp = Exec(
            \\UPDATE "
        ++ table ++
            \\" SET
            \\  "
        ++ @tagName(Column.timestamp) ++
            \\" = ?2
            \\WHERE "
        ++ @tagName(Column.callback) ++
            \\" = ?1
        , struct { i64, i64 });
    };

    pub const HttpCallback = struct {
        callback: i64,
        plugin: []const u8,

        const table = "http_callback";

        pub const Column = std.meta.FieldEnum(@This());

        pub const insert = SimpleInsert(table, @This());

        pub fn SelectCallbackByPlugin(comptime columns: []const Callback.Column) type {
            return Query(
                \\SELECT
            ++ " " ++ columnList(Callback.table, columns) ++
                \\
                \\FROM "
            ++ Callback.table ++
                \\"
                \\INNER JOIN "
            ++ table ++
                \\" ON "
            ++ table ++
                \\"."
            ++ @tagName(Column.callback) ++
                \\" = "
            ++ Callback.table ++
                \\"."
            ++ @tagName(Callback.Column.id) ++
                \\"
                \\WHERE "
            ++ table ++
                \\"."
            ++ @tagName(Column.plugin) ++
                \\" = ?
            ,
                false,
                meta.SubStruct(Callback, std.enums.EnumSet(Callback.Column).initMany(columns)),
                struct { []const u8 },
            );
        }
    };

    pub const NixBuildCallback = struct {
        callback: i64,
        installables: []const u8,

        const table = "nix_build_callback";

        pub const Column = std.meta.FieldEnum(@This());

        pub const insert = SimpleInsert(table, @This());

        pub fn Select(comptime columns: []const Column) type {
            return Query(
                \\SELECT
            ++ " " ++ columnList(table, columns) ++
                \\
                \\FROM "
            ++ table ++
                \\"
            ,
                true,
                meta.SubStruct(@This(), std.enums.EnumSet(Column).initMany(columns)),
                @TypeOf(.{}),
            );
        }

        pub fn SelectCallbackByInstallables(comptime columns: []const Callback.Column) type {
            return Query(
                \\SELECT
            ++ " " ++ columnList(Callback.table, columns) ++
                \\
                \\FROM "
            ++ Callback.table ++
                \\"
                \\INNER JOIN "
            ++ table ++
                \\" ON "
            ++ table ++
                \\"."
            ++ @tagName(Column.callback) ++
                \\" = "
            ++ Callback.table ++
                \\"."
            ++ @tagName(Callback.Column.id) ++
                \\"
                \\WHERE "
            ++ @tagName(Column.installables) ++
                \\" = ?
            ,
                true,
                meta.SubStruct(Callback, std.enums.EnumSet(Callback.Column).initMany(columns)),
                struct { []const u8 },
            );
        }

        pub fn encodeInstallables(allocator: std.mem.Allocator, installables: []const []const u8) ![]const u8 {
            const installables_mut = try allocator.dupe([]const u8, installables);
            defer allocator.free(installables_mut);

            std.mem.sortUnstable([]const u8, installables_mut, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);

            return std.mem.join(allocator, "\n", installables_mut);
        }

        pub fn decodeInstallables(allocator: std.mem.Allocator, installables: []const u8) ![]const []const u8 {
            var decoded = std.ArrayListUnmanaged([]const u8){};
            errdefer decoded.deinit(allocator);

            var iter = std.mem.splitScalar(u8, installables, '\n');
            while (iter.next()) |installable|
                try decoded.append(allocator, installable);

            return decoded.toOwnedSlice(allocator);
        }
    };

    pub const NixEvalCallback = struct {
        callback: i64,
        flake: ?[]const u8,
        expr: []const u8,
        format: i64,

        const table = "nix_eval_callback";

        pub const Column = std.meta.FieldEnum(@This());

        pub const insert = SimpleInsert(table, @This());

        pub fn Select(comptime columns: []const Column) type {
            return Query(
                \\SELECT
            ++ " " ++ columnList(table, columns) ++
                \\
                \\FROM "
            ++ table ++
                \\"
            ,
                true,
                meta.SubStruct(@This(), std.enums.EnumSet(Column).initMany(columns)),
                @TypeOf(.{}),
            );
        }

        pub fn SelectCallbackByFlakeAndExprAndFormat(comptime columns: []const Callback.Column) type {
            return Query(
                \\SELECT
            ++ " " ++ columnList(Callback.table, columns) ++
                \\
                \\FROM "
            ++ Callback.table ++
                \\"
                \\INNER JOIN "
            ++ table ++
                \\" ON "
            ++ table ++
                \\"."
            ++ @tagName(Column.callback) ++
                \\" = "
            ++ Callback.table ++
                \\"."
            ++ @tagName(Callback.Column.id) ++
                \\"
                \\WHERE "
            ++ @tagName(Column.flake) ++
                \\" IS ? AND "
            ++ @tagName(Column.expr) ++
                \\" = ? AND "
            ++ @tagName(Column.format) ++
                \\" = ?
            ,
                true,
                meta.SubStruct(Callback, std.enums.EnumSet(Callback.Column).initMany(columns)),
                struct { ?[]const u8, []const u8, i64 },
            );
        }
    };
};

test {
    std.testing.refAllDeclsRecursive(@This());
}
