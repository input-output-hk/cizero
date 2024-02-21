const std = @import("std");
const trait = @import("trait");
const zqlite = @import("zqlite");

const lib = @import("lib");
const enums = lib.enums;
const fmt = lib.fmt;
const meta = lib.meta;

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
    log.debug("trace: {}", .{fmt.oneline(std.mem.span(sql))});

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
        log.err("{s}: {s}. Statement: {}", .{ @errorName(err), conn.lastError(), fmt.oneline(sql) });
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

fn SimpleInsert(comptime table: []const u8, comptime Column: type) type {
    return Exec(
        \\INSERT INTO "
    ++ table ++
        \\" (
    ++ columnList(null, std.meta.fieldNames(Column)) ++
        \\) VALUES (
    ++ "?, " ** (std.meta.fields(Column).len - 1) ++ "?" ++
        \\)
    , meta.FieldsTuple(Column));
}

fn columnList(comptime table: ?[]const u8, comptime columns: anytype) []const u8 {
    comptime var selects: [columns.len][]const u8 = undefined;
    inline for (columns, &selects) |column, *select| {
        const column_name = if (trait.isZigString(@TypeOf(column))) column else @tagName(column);
        select.* = "\"" ++ column_name ++ "\"";
        if (table) |t| select.* = "\"" ++ t ++ "\"." ++ select.*;
    }
    return comptimeJoin(&selects, ", ");
}

test columnList {
    try std.testing.expectEqualStrings(
        \\"foo", "bar", "baz"
    , columnList(null, .{ .foo, .bar, .baz }));

    {
        const expected =
            \\"a"."foo", "a"."bar", "a"."baz"
        ;
        try std.testing.expectEqualStrings(expected, columnList("a", .{ .foo, .bar, .baz }));
        try std.testing.expectEqualStrings(expected, columnList("a", .{ "foo", "bar", "baz" }));
    }
}

fn comptimeJoin(comptime strs: []const []const u8, comptime sep: []const u8) []const u8 {
    comptime var result: []const u8 = "";
    inline for (strs, 0..) |str, i| {
        result = result ++ str;
        if (i + 1 < strs.len) result = result ++ sep;
    }
    return result;
}

test comptimeJoin {
    try std.testing.expectEqualStrings(
        \\a, b, c
    , comptimeJoin(&.{ "a", "b", "c" }, ", "));
    try std.testing.expectEqualStrings(
        \\a
    , comptimeJoin(&.{"a"}, ", "));
}

fn MergedColumns(
    comptime table_a: ?[]const u8,
    comptime ColumnA: type,
    comptime table_b: ?[]const u8,
    comptime ColumnB: type,
) type {
    const mapFn = struct {
        fn mapFn(comptime table: ?[]const u8, comptime T: type) fn (meta.FieldInfo(T)) meta.FieldInfo(T) {
            const fns = struct {
                fn map(field: meta.FieldInfo(T)) meta.FieldInfo(T) {
                    var f = field;
                    f.name = table.? ++ "." ++ f.name;
                    return f;
                }

                fn id(field: meta.FieldInfo(T)) meta.FieldInfo(T) {
                    return field;
                }
            };
            return if (table != null) fns.map else fns.id;
        }
    }.mapFn;

    return meta.MergedUnions(
        meta.MapTaggedUnionFields(ColumnA, mapFn(table_a, ColumnA), mapFn(table_a, @typeInfo(ColumnA).Union.tag_type.?)),
        meta.MapTaggedUnionFields(ColumnB, mapFn(table_b, ColumnB), mapFn(table_b, @typeInfo(ColumnB).Union.tag_type.?)),
        true,
    );
}

test MergedColumns {
    const ColumnA = union(enum) {
        foo: []const u8,
        bar: zqlite.Blob,
    };
    const ColumnB = union(enum) {
        foo: []const u8,
        baz: zqlite.Blob,
    };

    {
        const ColumnMerged = MergedColumns("a", ColumnA, "b", ColumnB);
        const column_names = std.meta.tags(std.meta.Tag(ColumnMerged));

        try std.testing.expectEqual(4, column_names.len);
        try std.testing.expectEqual(.@"a.foo", column_names[0]);
        try std.testing.expectEqual(.@"a.bar", column_names[1]);
        try std.testing.expectEqual(.@"b.foo", column_names[2]);
        try std.testing.expectEqual(.@"b.baz", column_names[3]);
    }

    {
        const ColumnMerged = MergedColumns(null, ColumnA, "b", ColumnB);
        const column_names = std.meta.tags(std.meta.Tag(ColumnMerged));

        try std.testing.expectEqual(4, column_names.len);
        try std.testing.expectEqual(.foo, column_names[0]);
        try std.testing.expectEqual(.bar, column_names[1]);
        try std.testing.expectEqual(.@"b.foo", column_names[2]);
        try std.testing.expectEqual(.@"b.baz", column_names[3]);
    }
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
            return Query(
                \\SELECT
                ++ " " ++ columnList(table, columns) ++
                    \\
                    \\FROM "
                ++ table ++
                    \\"
                    \\WHERE "
                ++ @tagName(ColumnName.name) ++
                    \\" = ?
            ,
                false,
                meta.SubUnion(Column, columns),
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
                meta.SubUnion(Column, columns),
                struct { i64 },
            );
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

        // XXX make these structs instead of unions so we can use them directly with `structFromRow()`
        pub const Column = union(enum) {
            callback: i64,
            timestamp: i64,
            cron: ?[]const u8,
        };
        pub const ColumnName = std.meta.Tag(Column);

        pub const insert = SimpleInsert(table, Column);

        pub fn SelectNext(comptime columns: []const ColumnName, comptime callback_columns: []const callback.ColumnName) type {
            return Query(
                \\SELECT
                ++ " " ++ comptimeJoin(&.{
                    columnList(table, columns),
                    columnList(callback.table, callback_columns),
                }, ", ") ++
                    \\
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
                MergedColumns(
                    null,
                    meta.SubUnion(Column, columns),
                    callback.table,
                    meta.SubUnion(callback.Column, callback_columns),
                ),
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
            plugin: []const u8,
        };
        pub const ColumnName = std.meta.Tag(Column);

        pub const insert = SimpleInsert(table, Column);

        pub fn SelectCallbackByPlugin(comptime columns: []const callback.ColumnName) type {
            return Query(
                \\SELECT
                ++ " " ++ columnList(callback.table, columns) ++
                    \\
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
                ++ table ++
                    \\"."
                ++ @tagName(ColumnName.plugin) ++
                    \\" = ?
            ,
                false,
                meta.SubUnion(callback.Column, columns),
                struct { []const u8 },
            );
        }
    };

    pub const nix_build_callback = struct {
        const table = "nix_build_callback";

        pub const Column = union(enum) {
            callback: i64,
            installable: []const u8,
        };
        pub const ColumnName = std.meta.Tag(Column);

        pub const insert = SimpleInsert(table, Column);

        pub fn Select(comptime columns: []const ColumnName) type {
            return Query(
                \\SELECT
                ++ " " ++ columnList(table, columns) ++
                    \\
                    \\FROM "
                ++ table ++
                    \\"
            ,
                true,
                meta.SubUnion(Column, columns),
                @TypeOf(.{}),
            );
        }

        pub fn SelectCallbackByInstallable(comptime columns: []const callback.ColumnName) type {
            return Query(
                \\SELECT
                ++ " " ++ columnList(callback.table, columns) ++
                    \\
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
                ++ @tagName(ColumnName.installable) ++
                    \\" = ?
            ,
                true,
                meta.SubUnion(callback.Column, columns),
                struct { []const u8 },
            );
        }
    };

    pub const nix_eval_callback = struct {
        const table = "nix_eval_callback";

        pub const Column = union(enum) {
            callback: i64,
            expr: []const u8,
            format: i64,
        };
        pub const ColumnName = std.meta.Tag(Column);

        pub const insert = SimpleInsert(table, Column);

        pub fn Select(comptime columns: []const ColumnName) type {
            return Query(
                \\SELECT
                ++ " " ++ columnList(table, columns) ++
                    \\
                    \\FROM "
                ++ table ++
                    \\"
            ,
                true,
                meta.SubUnion(Column, columns),
                @TypeOf(.{}),
            );
        }

        pub fn SelectCallbackByExprAndFormat(comptime columns: []const callback.ColumnName) type {
            return Query(
                \\SELECT
                ++ " " ++ columnList(callback.table, columns) ++
                    \\
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
                ++ @tagName(ColumnName.expr) ++
                    \\" = ? AND "
                ++ @tagName(ColumnName.format) ++
                    \\" = ?
            ,
                true,
                meta.SubUnion(callback.Column, columns),
                struct { []const u8, i64 },
            );
        }
    };
};

pub fn structFromRow(
    allocator: std.mem.Allocator,
    target_ptr: anytype,
    row: zqlite.Row,
    column_fn: anytype,
    comptime mapping: anytype,
) !void {
    const Target = std.meta.Child(@TypeOf(target_ptr));
    const target: *Target = @ptrCast(target_ptr);

    const mapping_fields = @typeInfo(@TypeOf(mapping)).Struct.fields;

    var allocated_mem: [mapping_fields.len][]const u8 = undefined;
    var allocated: usize = 0;
    var allocated_mem_z: [mapping_fields.len][:0]const u8 = undefined;
    var allocated_z: usize = 0;
    errdefer {
        for (allocated_mem[0..allocated]) |slice| allocator.free(slice);
        for (allocated_mem_z[0..allocated_z]) |slice_z| allocator.free(slice_z);
    }

    inline for (mapping_fields) |field| {
        const column = comptime @field(mapping, field.name);
        const value = column_fn(row, column);

        const target_field = &@field(target, field.name);

        target_field.* = switch (@TypeOf(target_field.*)) {
            []u8,
            []const u8,
            => blk: {
                const slice = try allocator.dupe(u8, value);
                allocated_mem[allocated] = slice;
                allocated += 1;
                break :blk slice;
            },
            ?[]u8,
            ?[]const u8,
            => if (value) |v| blk: {
                const slice = try allocator.dupe(u8, v);
                allocated_mem[allocated] = slice;
                allocated += 1;
                break :blk slice;
            } else null,

            [*]u8,
            [*]const u8,
            => blk: {
                const slice = try allocator.dupe(u8, value).ptr;
                allocated_mem[allocated] = slice;
                allocated += 1;
                break :blk slice;
            },
            ?[*]u8,
            ?[*]const u8,
            => if (value) |v| blk: {
                const slice = try allocator.dupe(u8, v).ptr;
                allocated_mem[allocated] = slice;
                allocated += 1;
                break :blk slice;
            } else null,

            [:0]u8,
            [:0]const u8,
            => blk: {
                const slice_z = try allocator.dupeZ(u8, value);
                allocated_mem_z[allocated_z] = slice_z;
                allocated_z += 1;
                break :blk slice_z;
            },
            ?[:0]u8,
            ?[:0]const u8,
            => if (value) |v| blk: {
                const slice_z = try allocator.dupeZ(u8, v);
                allocated_mem_z[allocated_z] = slice_z;
                allocated_z += 1;
                break :blk slice_z;
            } else null,

            [*:0]u8,
            [*:0]const u8,
            => blk: {
                const slice_z = try allocator.dupeZ(u8, value).ptr;
                allocated_mem_z[allocated_z] = slice_z;
                allocated_z += 1;
                break :blk slice_z;
            },
            ?[*:0]u8,
            ?[*:0]const u8,
            => if (value) |v| blk: {
                const slice_z = try allocator.dupeZ(u8, v).ptr;
                allocated_mem_z[allocated_z] = slice_z;
                allocated_z += 1;
                break :blk slice_z;
            } else null,

            zqlite.Blob => blk: {
                const slice = try allocator.dupe(u8, value);
                allocated_mem[allocated] = slice;
                allocated += 1;
                break :blk slice;
            },
            ?zqlite.Blob => if (value) |v| blk: {
                const slice = try allocator.dupe(u8, v);
                allocated_mem[allocated] = slice;
                allocated += 1;
                break :blk slice;
            } else null,

            else => value,
        };
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
