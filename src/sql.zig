const std = @import("std");
const trait = @import("trait");
const zqlite = @import("zqlite");

const lib = @import("lib");
const meta = lib.meta;
const enums = lib.enums;

const c = @import("c.zig");

const log_scope = .sql;
const log = std.log.scoped(log_scope);

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
            try logErr(conn, .execNoArgs, .{sql});
        }
        {
            const sql = "PRAGMA user_version = 1";
            try logErr(conn, .execNoArgs, .{sql});
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
    try logErr(conn, .execNoArgs, .{sql});
}

pub fn enableForeignKeys(conn: zqlite.Conn) !void {
    const sql = "PRAGMA foreign_keys = ON";
    try logErr(conn, .execNoArgs, .{sql});
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

fn logErr(conn: zqlite.Conn, comptime func_name: std.meta.DeclEnum(zqlite.Conn), args: anytype) zqlite.Error!(blk: {
    const func = @field(zqlite.Conn, @tagName(func_name));
    const func_info = @typeInfo(@TypeOf(func)).Fn;
    break :blk @typeInfo(func_info.return_type.?).ErrorUnion.payload;
}) {
    const func = @field(zqlite.Conn, @tagName(func_name));
    return if (@call(.auto, func, .{conn} ++ args)) |result| result else |err| blk: {
        const sql: []const u8 = args.@"0";
        log.err("{s}: {s}. Statement: {s}", .{ @errorName(err), conn.lastError(), sql });
        break :blk err;
    };
}

fn Query(comptime sql: []const u8, comptime multi: bool, comptime Columns: type, comptime Values_: type) type {
    return struct {
        pub const Column = std.meta.FieldEnum(Columns);
        pub const Values = Values_;

        fn getterResult(comptime Result: type) type {
            return switch (Result) {
                zqlite.Blob => []const u8,
                ?zqlite.Blob => ?[]const u8,
                else => Result,
            };
        }

        fn getter(comptime Result: type) fn (zqlite.Row, usize) getterResult(Result) {
            return switch (Result) {
                bool => zqlite.Row.boolean,
                ?bool => zqlite.Row.nullableBoolean,

                i64 => zqlite.Row.int,
                ?i64 => zqlite.Row.nullableInt,

                f64 => zqlite.Row.float,
                ?f64 => zqlite.Row.nullableFloat,

                []const u8 => zqlite.Row.text,
                ?[]const u8 => zqlite.Row.nullableText,

                [*:0]const u8 => zqlite.Row.textZ,
                ?[*:0]const u8 => zqlite.Row.nullableTextZ,
                usize => zqlite.Row.textLen,

                zqlite.Blob => zqlite.Row.blob,
                ?zqlite.Blob => zqlite.Row.nullableBlob,

                else => @compileError("There is no zqlite getter for type '" ++ @typeName(Result) ++ "'"),
            };
        }

        pub fn column(result: zqlite.Row, comptime col: Column) getterResult(std.meta.fieldInfo(Columns, col).type) {
            const info = std.meta.fieldInfo(Columns, col);
            const index = std.meta.fieldIndex(Columns, info.name).?;
            return getter(info.type)(result, index);
        }

        pub fn row(conn: zqlite.Conn, values: Values) !?zqlite.Row {
            return logErr(conn, .row, .{ sql, values });
        }

        pub usingnamespace if (multi) struct {
            pub fn rows(conn: zqlite.Conn, values: Values) !zqlite.Rows {
                return logErr(conn, .rows, .{ sql, values });
            }
        } else struct {};
    };
}

test Query {
    const Q = Query("SELECT a, b, c, d, e, f, g, h, i, j, k, l, m FROM foo", false, struct {
        a: bool,
        b: ?bool,
        c: i64,
        d: ?i64,
        e: f64,
        f: ?f64,
        g: []const u8,
        h: ?[]const u8,
        i: [*:0]const u8,
        j: ?[*:0]const u8,
        k: usize,
        l: zqlite.Blob,
        m: ?zqlite.Blob,
    }, struct {});

    try std.testing.expectEqual(bool, @TypeOf(Q.column(undefined, .a)));
    try std.testing.expectEqual(?bool, @TypeOf(Q.column(undefined, .b)));
    try std.testing.expectEqual(i64, @TypeOf(Q.column(undefined, .c)));
    try std.testing.expectEqual(?i64, @TypeOf(Q.column(undefined, .d)));
    try std.testing.expectEqual(f64, @TypeOf(Q.column(undefined, .e)));
    try std.testing.expectEqual(?f64, @TypeOf(Q.column(undefined, .f)));
    try std.testing.expectEqual([]const u8, @TypeOf(Q.column(undefined, .g)));
    try std.testing.expectEqual(?[]const u8, @TypeOf(Q.column(undefined, .h)));
    try std.testing.expectEqual([*:0]const u8, @TypeOf(Q.column(undefined, .i)));
    try std.testing.expectEqual(?[*:0]const u8, @TypeOf(Q.column(undefined, .j)));
    try std.testing.expectEqual(usize, @TypeOf(Q.column(undefined, .k)));
    try std.testing.expectEqual([]const u8, @TypeOf(Q.column(undefined, .l)));
    try std.testing.expectEqual(?[]const u8, @TypeOf(Q.column(undefined, .m)));

    try std.testing.expect(!std.meta.hasFn(Q, "rows"));
    try std.testing.expect(std.meta.hasFn(Query("", true, struct {}, struct {}), "rows"));
}

pub fn Exec(comptime sql: []const u8, comptime Values_: type) type {
    const Q = Query(sql, false, struct {}, Values_);

    return struct {
        pub const Values = Q.Values;

        pub fn exec(conn: zqlite.Conn, values: Values) !void {
            return logErr(conn, .exec, .{ sql, values });
        }

        pub usingnamespace if (@typeInfo(Values).Struct.fields.len == 0) struct {
            pub fn execNoArgs(conn: zqlite.Conn) !void {
                return logErr(conn, .execNoArgs, .{sql});
            }
        } else struct {};
    };
}

test Exec {
    try std.testing.expect(!std.meta.hasFn(Exec("", struct { a: u0 }), "execNoArgs"));
    try std.testing.expect(std.meta.hasFn(Exec("", struct {}), "execNoArgs"));
}

fn SimpleSelect(comptime Column: type, comptime columns: []const std.meta.FieldEnum(Column), comptime sql: []const u8, comptime multi: bool, comptime Values: type) type {
    return Query("SELECT " ++ columnList(columns) ++ "\n" ++ sql, multi, meta.SubUnion(Column, columns), Values);
}

fn SimpleInsert(comptime table: []const u8, comptime Column: type) type {
    return Exec(
        \\INSERT INTO "
    ++ table ++
        \\" (
    ++ columnList(std.meta.fieldNames(Column)) ++
        \\) VALUES (
    ++ "?, " ** (std.meta.fields(Column).len - 1) ++ "?" ++
        \\)
    , meta.FieldsTuple(Column));
}

fn SimpleSelectByRowid(comptime table: []const u8, comptime Column: type, comptime columns: []const std.meta.Tag(Column)) type {
    return SimpleSelect(
        Column,
        columns,
        \\FROM "
        ++ table ++
            \\"
            \\WHERE "rowid" = ?
    ,
        false,
        struct { i64 },
    );
}

fn columnList(comptime columns: anytype) []const u8 {
    comptime var sql: []const u8 = "";
    inline for (columns, 0..) |column, i| {
        const column_name = if (trait.isZigString(@TypeOf(column))) column else @tagName(column);
        sql = sql ++ "\"" ++ column_name ++ "\"";
        if (i + 1 < columns.len) sql = sql ++ ", ";
    }
    return sql;
}

test columnList {
    try std.testing.expectEqualStrings(
        \\"foo", "bar", "baz"
    , columnList(.{ .foo, .bar, .baz }));
    try std.testing.expectEqualStrings(
        \\"foo", "bar", "baz"
    , columnList(.{ "foo", "bar", "baz" }));
}

pub const queries = struct {
    pub const plugin = struct {
        const table = "plugin";

        pub const Column = union(enum) {
            name: []const u8,
            wasm: zqlite.Blob,
        };
        pub const ColumnName = std.meta.Tag(Column);

        pub const insert = SimpleInsert(table, Column);

        pub fn SelectByName(comptime columns: []const ColumnName) type {
            return SimpleSelect(
                Column,
                columns,
                \\FROM "
                ++ table ++
                    \\"
                    \\WHERE "
                ++ @tagName(ColumnName.name) ++
                    \\" = ?
            ,
                false,
                struct { []const u8 },
            );
        }
    };

    pub const callback = struct {
        const table = "callback";

        pub const Column = union(enum) {
            id: i64,
            plugin: []const u8,
            function: []const u8,
            user_data: ?zqlite.Blob,
        };
        pub const ColumnName = std.meta.Tag(Column);

        pub const insert = SimpleInsert(table, meta.SubUnion(Column, &.{ .plugin, .function, .user_data }));

        pub fn SelectById(comptime columns: []const ColumnName) type {
            return SimpleSelectByRowid(table, Column, columns);
        }

        pub const deleteById = Exec(
            \\DELETE FROM "
        ++ table ++
            \\"
            \\WHERE "
        ++ @tagName(ColumnName.id) ++
            \\" = ?
        , struct { i64 });
    };

    pub const timeout_callback = struct {
        const table = "timeout_callback";

        pub const Column = union(enum) {
            callback: i64,
            timestamp: i64,
            cron: ?[]const u8,
        };
        pub const ColumnName = std.meta.Tag(Column);

        pub const insert = SimpleInsert(table, Column);

        pub const ColumnJoined = meta.MergedUnions(callback.Column, Column, true);
        pub const ColumnNameJoined = std.meta.Tag(ColumnJoined);

        pub fn SelectNext(comptime columns: []const ColumnNameJoined) type {
            return SimpleSelect(
                ColumnJoined,
                columns,
                \\FROM "
                ++ callback.table ++
                    \\"
                    \\INNER JOIN "
                ++ table ++
                    \\" ON "
                ++ table ++
                    \\"."
                ++ @tagName(ColumnName.callback) ++
                    \\" = "
                ++ callback.table ++
                    \\"."
                ++ @tagName(callback.ColumnName.id) ++
                    \\"
                    \\ORDER BY "
                ++ @tagName(ColumnName.timestamp) ++
                    \\" ASC
                    \\LIMIT 1
            ,
                false,
                @TypeOf(.{}),
            );
        }

        pub const updateTimestamp = Exec(
            \\UPDATE "
        ++ table ++
            \\" SET
            \\  "
        ++ @tagName(ColumnName.timestamp) ++
            \\" = ?2
            \\WHERE "
        ++ @tagName(ColumnName.callback) ++
            \\" = ?1
        , struct { i64, i64 });
    };

    pub const http_callback = struct {
        const table = "http_callback";

        pub const Column = union(enum) {
            callback: i64,
        };
        pub const ColumnName = std.meta.Tag(Column);

        pub const insert = SimpleInsert(table, Column);

        pub fn SelectCallback(comptime columns: []const callback.ColumnName) type {
            return SimpleSelect(
                callback.Column,
                columns,
                \\FROM "
                ++ callback.table ++
                    \\"
                    \\INNER JOIN "
                ++ table ++
                    \\" ON "
                ++ table ++
                    \\"."
                ++ @tagName(ColumnName.callback) ++
                    \\" = "
                ++ callback.table ++
                    \\"."
                ++ @tagName(callback.ColumnName.id) ++
                    \\"
            ,
                true,
                @TypeOf(.{}),
            );
        }
    };

    pub const nix_callback = struct {
        const table = "nix_callback";

        pub const Column = union(enum) {
            callback: i64,
            flake_url: []const u8,
        };
        pub const ColumnName = std.meta.Tag(Column);

        pub const insert = SimpleInsert(table, Column);

        pub const ColumnJoined = meta.MergedUnions(callback.Column, Column, true);
        pub const ColumnNameJoined = std.meta.Tag(ColumnJoined);

        pub fn Select(comptime columns: []const ColumnName) type {
            return SimpleSelect(
                Column,
                columns,
                \\FROM "
                ++ table ++
                    \\"
            ,
                true,
                @TypeOf(.{}),
            );
        }

        pub fn SelectCallbackByFlakeUrl(comptime columns: []const ColumnNameJoined) type {
            return SimpleSelect(
                ColumnJoined,
                columns,
                \\FROM "
                ++ callback.table ++
                    \\"
                    \\INNER JOIN "
                ++ table ++
                    \\" ON "
                ++ table ++
                    \\"."
                ++ @tagName(ColumnName.callback) ++
                    \\" = "
                ++ callback.table ++
                    \\"."
                ++ @tagName(callback.ColumnName.id) ++
                    \\"
                    \\WHERE "
                ++ @tagName(ColumnName.flake_url) ++
                    \\" = ?
            ,
                true,
                struct { []const u8 },
            );
        }
    };
};

test {
    std.testing.refAllDeclsRecursive(@This());
}
