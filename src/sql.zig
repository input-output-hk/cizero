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

fn Query(comptime sql: []const u8, comptime multi: bool, comptime Row: type, comptime Values_: type) type {
    return struct {
        pub const Column = std.meta.FieldEnum(Row);
        pub const Values = Values_;

        fn GetterResult(comptime Result: type) type {
            return switch (Result) {
                zqlite.Blob => []const u8,
                ?zqlite.Blob => ?[]const u8,
                else => Result,
            };
        }

        fn getter(comptime Result: type) fn (zqlite.Row, usize) GetterResult(Result) {
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

        fn column(result: zqlite.Row, comptime col: Column) GetterResult(std.meta.fieldInfo(Row, col).type) {
            const info = std.meta.fieldInfo(Row, col);
            const index = std.meta.fieldIndex(Row, info.name).?;
            return getter(info.type)(result, index);
        }

        pub usingnamespace if (multi) struct {
            fn rows(conn: zqlite.Conn, values: Values) !zqlite.Rows {
                return logErr(conn, .rows, .{ sql, values });
            }

            pub const Rows = struct {
                zqlite_rows: zqlite.Rows,
                allocator: std.mem.Allocator,

                pub fn deinit(self: @This()) void {
                    self.zqlite_rows.deinit();
                }

                pub fn deinitErr(self: @This()) !void {
                    try self.zqlite_rows.deinitErr();
                }

                pub fn next(self: *@This()) !?Row {
                    if (self.zqlite_rows.next()) |zqlite_row| {
                        var arena = std.heap.ArenaAllocator.init(self.allocator);
                        errdefer arena.deinit();

                        var typed_row: Row = undefined;
                        try structFromRow(arena.allocator(), &typed_row, zqlite_row, column);

                        return typed_row;
                    }
                    return null;
                }

                /// Consumes this so `deinit()` or `deinitErr()` no longer have to be called.
                pub fn toOwnedSlice(self: *@This()) ![]Row {
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    errdefer arena.deinit();

                    var this = @This(){
                        .zqlite_rows = self.zqlite_rows,
                        .allocator = arena.allocator(),
                    };
                    errdefer this.deinit();

                    var typed_rows = std.ArrayListUnmanaged(Row){};
                    errdefer typed_rows.deinit(this.allocator);

                    while (try this.next()) |typed_row|
                        (try typed_rows.addOne(this.allocator)).* = typed_row;

                    try this.deinitErr();

                    return typed_rows.toOwnedSlice(this.allocator);
                }
            };

            pub fn queryIterator(allocator: std.mem.Allocator, conn: zqlite.Conn, values: Values) !Rows {
                return .{
                    .zqlite_rows = try rows(conn, values),
                    .allocator = allocator,
                };
            }

            pub fn query(allocator: std.mem.Allocator, conn: zqlite.Conn, values: Values) ![]Row {
                var iter = try queryIterator(allocator, conn, values);
                return iter.toOwnedSlice();
            }
        } else struct {
            fn row(conn: zqlite.Conn, values: Values) !?zqlite.Row {
                return logErr(conn, .row, .{ sql, values });
            }

            pub fn query(allocator: std.mem.Allocator, conn: zqlite.Conn, values: Values) !?Row {
                const zqlite_row = try row(conn, values) orelse return null;
                errdefer zqlite_row.deinit();

                var arena = std.heap.ArenaAllocator.init(allocator);
                errdefer arena.deinit();

                var typed_row: Row = undefined;
                try structFromRow(arena.allocator(), &typed_row, zqlite_row, column);

                try zqlite_row.deinitErr();

                return typed_row;
            }
        };
    };
}

test Query {
    {
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
    }

    {
        const Row = struct {};
        const Q = Query("", false, Row, struct {});
        try std.testing.expectEqualDeep(@typeInfo(@typeInfo(@typeInfo(@TypeOf(Q.query)).Fn.return_type.?).ErrorUnion.payload), @typeInfo(?Row));
    }

    {
        const Row = struct {};
        const Q = Query("", true, Row, struct {});
        try std.testing.expectEqualDeep(@typeInfo(std.meta.Elem(@typeInfo(@typeInfo(@TypeOf(Q.query)).Fn.return_type.?).ErrorUnion.payload)), @typeInfo(Row));
    }
}

pub fn Exec(comptime sql: []const u8, comptime Values_: type) type {
    const Q = Query(sql, false, struct {}, Values_);

    return struct {
        pub const Values = Q.Values;

        pub usingnamespace if (@typeInfo(Values).Struct.fields.len == 0) struct {
            pub fn execNoArgs(conn: zqlite.Conn) !void {
                return logErr(conn, .execNoArgs, .{sql});
            }
        } else struct {
            pub fn exec(conn: zqlite.Conn, values: Values) !void {
                return logErr(conn, .exec, .{ sql, values });
            }
        };
    };
}

test Exec {
    {
        const E = Exec("", struct { a: u0 });
        try std.testing.expect(std.meta.hasFn(E, "exec"));
        try std.testing.expect(!std.meta.hasFn(E, "execNoArgs"));
    }

    {
        const E = Exec("", struct {});
        try std.testing.expect(std.meta.hasFn(E, "execNoArgs"));
        try std.testing.expect(!std.meta.hasFn(E, "exec"));
    }
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
    return comptime comptimeJoin(&selects, ", ");
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

fn MergedTables(
    comptime a_qualification: ?[]const u8,
    comptime A: type,
    comptime b_qualification: ?[]const u8,
    comptime B: type,
) type {
    const mapFn = struct {
        fn mapFn(comptime table: []const u8, comptime T: type) fn (meta.FieldInfo(T)) meta.FieldInfo(T) {
            return struct {
                fn map(field: meta.FieldInfo(T)) meta.FieldInfo(T) {
                    var f = field;
                    f.name = table ++ "." ++ f.name;
                    return f;
                }
            }.map;
        }
    }.mapFn;

    return meta.MergedStructs(
        if (a_qualification) |qualification| meta.MapFields(A, mapFn(qualification, A)) else A,
        if (b_qualification) |qualification| meta.MapFields(B, mapFn(qualification, B)) else B,
    );
}

test MergedTables {
    const TableA = struct {
        foo: []const u8,
        bar: zqlite.Blob,
    };
    const TableB = struct {
        foo: []const u8,
        baz: zqlite.Blob,
    };

    {
        const TableMerged = MergedTables("a", TableA, "b", TableB);
        const column_names = std.meta.tags(std.meta.FieldEnum(TableMerged));

        try std.testing.expectEqual(4, column_names.len);
        try std.testing.expectEqual(.@"a.foo", column_names[0]);
        try std.testing.expectEqual(.@"a.bar", column_names[1]);
        try std.testing.expectEqual(.@"b.foo", column_names[2]);
        try std.testing.expectEqual(.@"b.baz", column_names[3]);
    }

    {
        const TableMerged = MergedTables(null, TableA, "b", TableB);
        const column_names = std.meta.tags(std.meta.FieldEnum(TableMerged));

        try std.testing.expectEqual(4, column_names.len);
        try std.testing.expectEqual(.foo, column_names[0]);
        try std.testing.expectEqual(.bar, column_names[1]);
        try std.testing.expectEqual(.@"b.foo", column_names[2]);
        try std.testing.expectEqual(.@"b.baz", column_names[3]);
    }
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
                meta.SubStruct(@This(), columns),
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

        pub const insert = SimpleInsert(table, meta.SubStruct(@This(), &.{ .plugin, .function, .user_data }));

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
                ++ " " ++ comptimeJoin(&.{
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
                    meta.SubStruct(@This(), columns),
                    Callback.table,
                    meta.SubStruct(Callback, callback_columns),
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
                meta.SubStruct(Callback, columns),
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
                meta.SubStruct(@This(), columns),
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
                meta.SubStruct(Callback, columns),
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
                meta.SubStruct(@This(), columns),
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
                meta.SubStruct(Callback, columns),
                struct { ?[]const u8, []const u8, i64 },
            );
        }
    };
};

fn structFromRow(
    allocator: std.mem.Allocator,
    target_ptr: anytype,
    row: zqlite.Row,
    column_fn: anytype,
) !void {
    const Target = std.meta.Child(@TypeOf(target_ptr));
    const target: *Target = @ptrCast(target_ptr);

    const fields = comptime std.enums.values(std.meta.FieldEnum(Target));

    var allocated_mem: [fields.len][]const u8 = undefined;
    var allocated: usize = 0;
    var allocated_mem_z: [fields.len][:0]const u8 = undefined;
    var allocated_z: usize = 0;
    errdefer {
        for (allocated_mem[0..allocated]) |slice| allocator.free(slice);
        for (allocated_mem_z[0..allocated_z]) |slice_z| allocator.free(slice_z);
    }

    inline for (fields) |field| {
        const value = column_fn(row, field);

        const target_field = &@field(target, @tagName(field));

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
                break :blk .{ .value = slice };
            },
            ?zqlite.Blob => if (value) |v| blk: {
                const slice = try allocator.dupe(u8, v);
                allocated_mem[allocated] = slice;
                allocated += 1;
                break :blk .{ .value = slice };
            } else null,

            else => value,
        };
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
