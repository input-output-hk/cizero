const std = @import("std");

const lib = @import("lib");
const mem = lib.mem;
const wasm = lib.wasm;

const c = @import("c.zig");
const fs = @import("fs.zig");
const wasmtime = @import("wasmtime.zig");

wasm_engine: *c.wasm_engine_t,
wasm_store: *c.wasmtime_store,
wasm_context: *c.wasmtime_context,
wasm_instance: c.wasmtime_instance,

// WASI config to apply before calling functions.
// This cannot be applied directly due to issues with logging:
//
// Applying the WASI config truncates the stdout and stderr files, if any.
//
// In order to log output in `call()`, we first make a new WASI config
// that points to the files that wasmtime should log to.
// Before returning from `call()` we have to reapply the previous WASI config
// though, because if we didn't, calling a function would change the WASI config,
// which the caller would not expect.
//
// However, reapplying the previous WASI config
// would immediately truncate the stdout and stderr files.
// That doesn't matter to our own logging, because at that time
// we have already read and logged the output;
// the caller however might still want to read those files.
// That could be the case if he initially created them and we're just leaving them in place.
// In that case, we would have truncated files the caller is about to read!
//
// So resetting before returing is not an option.
// By delaying application until right before actually calling a function,
// we are making sure the stdout and stderr files
// are not truncated unless we are about to write to them.
wasi_config: ?*const WasiConfig = null,

allocator: std.mem.Allocator,

plugin_name: []const u8,
plugin_wasm: []const u8,

host_functions: std.StringArrayHashMapUnmanaged(HostFunction),

pub const WasiConfig = struct {
    argv: ?[]const []const u8 = null,
    env: ?union(enum) {
        inherit,
        env: std.StringArrayHashMapUnmanaged([]const u8),
    } = null,
    stdin: ?union(enum) {
        inherit,
        buffer: []const u8,
        file: []const u8,
    } = null,
    stdout: ?Stdio = null,
    stderr: ?Stdio = null,

    pub const Stdio = union(enum) {
        inherit,
        file: []const u8,
    };

    pub const CollectOutput = struct {
        allocator: std.mem.Allocator,
        stdout: StdioFile,
        stderr: StdioFile,

        pub const StdioFile = union(enum) {
            own: fs.TmpFile,
            brw: []const u8,

            pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
                switch (self) {
                    .own => |own| own.deinit(alloc),
                    .brw => {},
                }
            }

            fn path(self: @This()) []const u8 {
                return switch (self) {
                    .own => |own| own.path,
                    .brw => |brw| brw,
                };
            }

            fn read(self: @This(), alloc: std.mem.Allocator, max_bytes: usize) ![]u8 {
                return switch (self) {
                    .own => |own| own.file.readToEndAlloc(alloc, max_bytes),
                    .brw => |brw| blk: {
                        const file = try std.fs.openFileAbsolute(brw, .{});
                        defer file.close();

                        break :blk file.readToEndAlloc(alloc, max_bytes);
                    },
                };
            }
        };

        pub const Output = struct {
            allocator: std.mem.Allocator,
            stdout: []u8,
            stderr: []u8,

            pub fn deinit(self: @This()) void {
                self.allocator.free(self.stdout);
                self.allocator.free(self.stderr);
            }
        };

        pub fn deinit(self: @This()) void {
            self.stdout.deinit(self.allocator);
            self.stderr.deinit(self.allocator);
        }

        pub fn collect(self: @This(), max_bytes: usize) !Output {
            const stdout = try self.stdout.read(self.allocator, max_bytes);
            errdefer self.allocator.free(stdout);

            const stderr = try self.stderr.read(self.allocator, max_bytes);
            errdefer self.allocator.free(stderr);

            return .{
                .allocator = self.allocator,
                .stdout = stdout,
                .stderr = stderr,
            };
        }
    };

    pub fn collectOutput(self: *@This(), allocator: std.mem.Allocator) !CollectOutput {
        const keep_stdout = self.stdout != null and self.stdout.? == .file;
        const keep_stderr = self.stderr != null and self.stderr.? == .file;

        const stdout: CollectOutput.StdioFile = if (keep_stdout) .{ .brw = self.stdout.?.file } else .{ .own = try fs.tmpFile(allocator, .{ .read = true }) };
        errdefer stdout.deinit(allocator);

        const stderr: CollectOutput.StdioFile = if (keep_stderr) .{ .brw = self.stderr.?.file } else .{ .own = try fs.tmpFile(allocator, .{ .read = true }) };
        errdefer stderr.deinit(allocator);

        const collect = .{
            .allocator = allocator,
            .stdout = stdout,
            .stderr = stderr,
        };

        self.stdout = .{ .file = stdout.path() };
        self.stderr = .{ .file = stderr.path() };

        return collect;
    }

    fn new(self: @This(), allocator: std.mem.Allocator) !*c.wasi_config_t {
        const wasi_config = c.wasi_config_new().?;

        if (self.argv) |argv| {
            const argv_z = try allocator.alloc([:0]const u8, argv.len);
            defer {
                for (argv_z) |arg_z| allocator.free(arg_z);
                allocator.free(argv_z);
            }

            const argv_c = try allocator.alloc([*c]const u8, argv_z.len);
            defer allocator.free(argv_c);

            for (argv, argv_z, argv_c) |arg, *arg_z, *arg_c| {
                arg_z.* = try allocator.dupeZ(u8, arg);
                arg_c.* = arg_z.*.ptr;
            }

            c.wasi_config_set_argv(wasi_config, @intCast(argv_c.len), argv_c.ptr);
        }

        if (self.env) |env_config| switch (env_config) {
            .inherit => c.wasi_config_inherit_env(wasi_config),
            .env => |env| {
                const keys_z = try allocator.alloc([:0]const u8, env.count());
                defer {
                    for (keys_z) |key_z| allocator.free(key_z);
                    allocator.free(keys_z);
                }

                const keys_c = try allocator.alloc([*c]const u8, keys_z.len);
                defer allocator.free(keys_c);

                const values_z = try allocator.alloc([:0]const u8, keys_z.len);
                defer {
                    for (values_z) |value_z| allocator.free(value_z);
                    allocator.free(values_z);
                }

                const values_c = try allocator.alloc([*c]const u8, values_z.len);
                defer allocator.free(values_c);

                for (env.keys(), env.values(), keys_z, values_z, keys_c, values_c) |key, value, *key_z, *value_z, *key_c, *value_c| {
                    key_z.* = try allocator.dupeZ(u8, key);
                    value_z.* = try allocator.dupeZ(u8, value);

                    key_c.* = key_z.*.ptr;
                    value_c.* = value_z.*.ptr;
                }

                c.wasi_config_set_env(wasi_config, @intCast(keys_c.len), keys_c.ptr, values_c.ptr);
            },
        };

        if (self.stdin) |stdin_config| switch (stdin_config) {
            .inherit => c.wasi_config_inherit_stdin(wasi_config),
            .buffer => |buffer| {
                var wasm_buffer: c.wasm_byte_vec_t = undefined;
                c.wasm_byte_vec_new(&wasm_buffer, buffer.len, buffer.ptr);
                errdefer c.wasm_byte_vec_delete(&wasm_buffer);

                c.wasi_config_set_stdin_bytes(wasi_config, &wasm_buffer);
            },
            .file => |path| {
                const path_z = try allocator.dupeZ(c.wasm_byte_t, path);
                defer allocator.free(path_z);

                if (!c.wasi_config_set_stdin_file(wasi_config, path_z)) return error.WasiFileNotFound;
            },
        };

        if (self.stdout) |stdout_config| switch (stdout_config) {
            .inherit => c.wasi_config_inherit_stdout(wasi_config),
            .file => |path| {
                const path_z = try allocator.dupeZ(c.wasm_byte_t, path);
                defer allocator.free(path_z);

                if (!c.wasi_config_set_stdout_file(wasi_config, path_z)) return error.WasiFileNotFound;
            },
        };

        if (self.stderr) |stderr_config| switch (stderr_config) {
            .inherit => c.wasi_config_inherit_stderr(wasi_config),
            .file => |path| {
                const path_z = try allocator.dupeZ(c.wasm_byte_t, path);
                defer allocator.free(path_z);

                if (!c.wasi_config_set_stderr_file(wasi_config, path_z)) return error.WasiFileNotFound;
            },
        };

        return wasi_config;
    }
};

pub fn deinit(self: *@This()) void {
    const self_on_heap: *@This() = @alignCast(@ptrCast(c.wasmtime_context_get_data(self.wasm_context)));
    self.allocator.destroy(self_on_heap);

    self.host_functions.deinit(self.allocator);

    self.allocator.free(self.plugin_name);
    self.allocator.free(self.plugin_wasm);

    c.wasmtime_store_delete(self.wasm_store);
    c.wasm_engine_delete(self.wasm_engine);
}

pub fn init(
    allocator: std.mem.Allocator,
    plugin_name: []const u8,
    plugin_wasm: []const u8,
    host_function_defs: std.StringArrayHashMapUnmanaged(HostFunctionDef),
) !@This() {
    const wasm_engine = blk: {
        const wasm_config = c.wasm_config_new();
        c.wasmtime_config_epoch_interruption_set(wasm_config, true);

        break :blk c.wasm_engine_new_with_config(wasm_config).?;
    };
    errdefer c.wasm_engine_delete(wasm_engine);
    const wasm_store = c.wasmtime_store_new(wasm_engine, null, null).?;
    errdefer c.wasmtime_store_delete(wasm_store);
    const wasm_context = c.wasmtime_store_context(wasm_store).?;
    c.wasmtime_context_set_epoch_deadline(wasm_context, 1);

    const wasm_linker = c.wasmtime_linker_new(wasm_engine).?;
    defer c.wasmtime_linker_delete(wasm_linker);
    try handleError(
        "failed to link WASI",
        c.wasmtime_linker_define_wasi(wasm_linker),
        null,
    );

    var host_functions = std.StringArrayHashMapUnmanaged(HostFunction){};
    {
        try host_functions.ensureTotalCapacity(allocator, host_function_defs.count());

        var host_function_defs_iter = host_function_defs.iterator();
        while (host_function_defs_iter.next()) |def_entry| {
            const gop_result = host_functions.getOrPutAssumeCapacity(def_entry.key_ptr.*);
            gop_result.value_ptr.* = def_entry.value_ptr.host_function;

            std.log.debug("linking host function \"{s}\"…", .{gop_result.key_ptr.*});

            const host_module_name = "cizero";

            const signature = try wasmtime.functype(allocator, def_entry.value_ptr.signature);
            errdefer c.wasm_functype_delete(signature);

            try handleError(
                "failed to define function",
                c.wasmtime_linker_define_func(
                    wasm_linker,
                    host_module_name,
                    host_module_name.len,
                    gop_result.key_ptr.ptr,
                    gop_result.key_ptr.len,
                    signature,
                    dispatchHostFunction,
                    gop_result.value_ptr,
                    null,
                ),
                null,
            );
        }
    }

    const plugin_name_copy = try allocator.dupe(u8, plugin_name);
    errdefer allocator.free(plugin_name_copy);

    const plugin_wasm_copy = try allocator.dupe(u8, plugin_wasm);
    errdefer allocator.free(plugin_wasm_copy);

    var self = @This(){
        .wasm_engine = wasm_engine,
        .wasm_store = wasm_store,
        .wasm_context = wasm_context,
        .allocator = allocator,
        .plugin_name = plugin_name_copy,
        .plugin_wasm = plugin_wasm_copy,
        .host_functions = host_functions,
        .wasm_instance = undefined,
    };

    {
        var wasm_module: ?*c.wasmtime_module = undefined;
        defer c.wasmtime_module_delete(wasm_module);
        try handleError(
            "failed to compile module",
            // XXX do we really have to keep plugin_wasm alive?
            c.wasmtime_module_new(wasm_engine, self.plugin_wasm.ptr, self.plugin_wasm.len, &wasm_module),
            null,
        );

        var trap: ?*c.wasm_trap_t = null;
        try handleError(
            "failed to instantiate module",
            c.wasmtime_linker_instantiate(wasm_linker, wasm_context, wasm_module, &self.wasm_instance, &trap),
            trap,
        );
    }

    {
        // Make a copy that lives on the heap and therefore has a stable address
        // that we can safely get and dereference from `wasm_context_get_data()`
        // even after `init()` returns and `self` is destroyed.
        // It is crucial that no fields are ever modified
        // as that would lead to changes between the copy on stack and heap.
        // If we need to modify fields in the future, we need to change the `init` function
        // so that it returns a pointer to heap memory, and set that pointer
        // as context data instead of making a copy.
        const self_on_heap = try allocator.create(@This());
        errdefer allocator.destroy(self_on_heap);
        self_on_heap.* = self;
        c.wasmtime_context_set_data(self.wasm_context, self_on_heap);
    }

    return self;
}

fn configureWasi(self: @This(), wasi_config: WasiConfig) !void {
    var new_wasi_config = wasi_config;

    var args: ?[][]const u8 = null;
    defer if (args) |a| self.allocator.free(a);
    {
        const default_args: []const []const u8 = &.{self.plugin_name};
        new_wasi_config.argv = if (new_wasi_config.argv) |argv| blk: {
            args = try self.allocator.alloc([]const u8, default_args.len + argv.len);
            @memcpy(args.?[0..default_args.len], default_args);
            @memcpy(args.?[default_args.len..], argv);
            break :blk args.?;
        } else default_args;
    }

    try handleError(
        "failed to configure WASI",
        c.wasmtime_context_set_wasi(self.wasm_context, try new_wasi_config.new(self.allocator)),
        null,
    );
}

pub const HostFunctionDef = struct {
    signature: wasm.Type,
    host_function: HostFunction,
};

pub const HostFunction = struct {
    callback: *const Callback,
    user_data: ?*anyopaque,

    pub const Callback = fn (?*anyopaque, plugin_name: []const u8, []u8, std.mem.Allocator, []const wasm.Value, []wasm.Value) anyerror!void;

    pub fn init(callback: anytype, user_data: ?*anyopaque) @This() {
        comptime {
            const T = @typeInfo(@TypeOf(callback)).Fn;
            if (T.params[1].type.? != []const u8 or
                T.params[2].type.? != []u8 or
                T.params[3].type.? != std.mem.Allocator or
                T.params[4].type.? != []const wasm.Value or
                T.params[5].type.? != []wasm.Value or
                @typeInfo(T.return_type.?).ErrorUnion.payload != void)
                @compileError("bad callback signature");
        }
        return .{
            .callback = @ptrCast(&callback),
            .user_data = user_data,
        };
    }

    fn call(self: @This(), plugin_name: []const u8, memory: []u8, allocator: std.mem.Allocator, inputs: []const wasm.Value, outputs: []wasm.Value) anyerror!void {
        return self.callback(self.user_data, plugin_name, memory, allocator, inputs, outputs);
    }
};

fn dispatchHostFunction(
    user_data: ?*anyopaque,
    caller: ?*c.wasmtime_caller,
    inputs: [*c]const c.wasmtime_val,
    inputs_len: usize,
    outputs: [*c]c.wasmtime_val,
    outputs_len: usize,
) callconv(.C) ?*c.wasm_trap_t {
    const self: *@This() = @alignCast(@ptrCast(c.wasmtime_context_get_data(c.wasmtime_caller_context(caller))));

    const memory = Memory.initFromCaller(caller.?) catch |err| return errorTrap(err);
    const allocator = Allocator.initFromCaller(memory, caller.?) catch |err| return errorTrap(err);

    const input_vals = self.allocator.alloc(wasm.Value, inputs_len) catch |err| return errorTrap(err);
    for (input_vals, inputs) |*val, *input| val.* = wasmtime.fromVal(@ptrCast(input)) catch |err| return errorTrap(err);
    defer self.allocator.free(input_vals);

    const output_vals = self.allocator.alloc(wasm.Value, outputs_len) catch |err| return errorTrap(err);
    defer self.allocator.free(output_vals);

    const host_function: *const HostFunction = @alignCast(@ptrCast(user_data));
    host_function.call(self.plugin_name, memory.slice(), allocator.allocator(), input_vals, output_vals) catch |err| return errorTrap(err);

    for (output_vals, outputs) |val, *output| output.* = wasmtime.val(val);

    return null;
}

inline fn errorTrap(err: anyerror) *c.wasm_trap_t {
    const msg = @errorName(err);
    if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
    return c.wasmtime_trap_new(msg, msg.len) orelse std.debug.panic("could not allocate trap: {s}", .{msg});
}

pub const Memory = struct {
    wasm_memory: c.wasmtime_memory,
    wasm_context: *c.wasmtime_context,

    const export_name = "memory";

    fn initFromCaller(caller: *c.wasmtime_caller) !@This() {
        var item: c.wasmtime_extern = undefined;
        if (!c.wasmtime_caller_export_get(caller, export_name, export_name.len, &item)) return error.NoSuchItem;
        return initFromExtern(item, c.wasmtime_caller_context(caller).?);
    }

    fn initFromLinker(linker: *const c.wasmtime_linker, context: *c.wasmtime_context) !@This() {
        var item: c.wasmtime_extern = undefined;
        if (!c.wasmtime_linker_get(linker, context, null, 0, export_name, export_name.len, &item)) return error.NoSuchItem;
        return initFromExtern(item, context);
    }

    fn initFromInstance(instance: c.wasmtime_instance, context: *c.wasmtime_context) !@This() {
        var item: c.wasmtime_extern = undefined;
        if (!c.wasmtime_instance_export_get(context, &instance, export_name, export_name.len, &item)) return error.NoSuchItem;
        return initFromExtern(item, context);
    }

    fn initFromExtern(item_memory: c.wasmtime_extern, context: *c.wasmtime_context) !@This() {
        if (item_memory.kind != c.WASMTIME_EXTERN_MEMORY) return error.NotAMemory;

        return .{
            .wasm_memory = item_memory.of.memory,
            .wasm_context = context,
        };
    }

    pub fn slice(self: @This()) []u8 {
        const ptr = c.wasmtime_memory_data(self.wasm_context, &self.wasm_memory);
        const len = c.wasmtime_memory_data_size(self.wasm_context, &self.wasm_memory);
        return ptr[0..len];
    }

    pub fn offset(self: @This(), ptr: anytype) wasm.usize {
        const ptr_addr = @intFromPtr(ptr);

        const memory = self.slice();
        const memory_addr = @intFromPtr(memory.ptr);

        if (switch (memory.len) {
            0 => ptr_addr != memory_addr,
            else => ptr_addr < memory_addr or ptr_addr >= memory_addr + memory.len,
        }) std.debug.panic("ptr {*} is not in slice at {*} of length {d}\n", .{ ptr, memory.ptr, memory.len });

        return @intCast(ptr_addr - memory_addr);
    }
};

pub const Allocator = struct {
    memory: Memory,
    wasm_fn_alloc: c.wasmtime_func,
    wasm_fn_resize: c.wasmtime_func,
    wasm_fn_free: c.wasmtime_func,

    const export_names = .{ "cizero_mem_alloc", "cizero_mem_resize", "cizero_mem_free" };

    fn initFromCaller(memory: Memory, caller: *c.wasmtime_caller) !@This() {
        var item_fn_alloc: c.wasmtime_extern = undefined;
        var item_fn_resize: c.wasmtime_extern = undefined;
        var item_fn_free: c.wasmtime_extern = undefined;

        inline for (
            .{ &item_fn_alloc, &item_fn_resize, &item_fn_free },
            export_names,
        ) |item, export_name|
            if (!c.wasmtime_caller_export_get(caller, export_name, export_name.len, item)) return error.NoSuchItem;

        return initFromExterns(
            memory,
            item_fn_alloc,
            item_fn_resize,
            item_fn_free,
        );
    }

    fn initFromLinker(memory: Memory, linker: *const c.wasmtime_linker) !@This() {
        var item_fn_alloc: c.wasmtime_extern = undefined;
        var item_fn_resize: c.wasmtime_extern = undefined;
        var item_fn_free: c.wasmtime_extern = undefined;

        inline for (
            .{ &item_fn_alloc, &item_fn_resize, &item_fn_free },
            export_names,
        ) |item, export_name|
            if (!c.wasmtime_linker_get(linker, memory.wasm_context, null, 0, export_name, export_name.len, item)) return error.NoSuchItem;

        return initFromExterns(
            memory,
            item_fn_alloc,
            item_fn_resize,
            item_fn_free,
        );
    }

    fn initFromInstance(memory: Memory, instance: c.wasmtime_instance) !@This() {
        var item_fn_alloc: c.wasmtime_extern = undefined;
        var item_fn_resize: c.wasmtime_extern = undefined;
        var item_fn_free: c.wasmtime_extern = undefined;

        inline for (
            .{ &item_fn_alloc, &item_fn_resize, &item_fn_free },
            export_names,
        ) |item, export_name|
            if (!c.wasmtime_instance_export_get(memory.wasm_context, &instance, export_name, export_name.len, item)) return error.NoSuchItem;

        return initFromExterns(
            memory,
            item_fn_alloc,
            item_fn_resize,
            item_fn_free,
        );
    }

    fn initFromExterns(
        memory: Memory,
        item_fn_alloc: c.wasmtime_extern,
        item_fn_resize: c.wasmtime_extern,
        item_fn_free: c.wasmtime_extern,
    ) !@This() {
        inline for (.{ item_fn_alloc, item_fn_resize, item_fn_free }) |item|
            if (item.kind != c.WASMTIME_EXTERN_FUNC) return error.NotAFunction;

        return .{
            .memory = memory,
            .wasm_fn_alloc = item_fn_alloc.of.func,
            .wasm_fn_resize = item_fn_resize.of.func,
            .wasm_fn_free = item_fn_free.of.func,
        };
    }

    pub fn allocator(self: *const @This()) std.mem.Allocator {
        return .{
            .ptr = @constCast(self),
            .vtable = &std.mem.Allocator.VTable{
                .alloc = @ptrCast(&alloc),
                .resize = @ptrCast(&resize),
                .free = @ptrCast(&free),
            },
        };
    }

    fn alloc(self: *const @This(), len: usize, ptr_align: u8, _: usize) ?[*]u8 {
        var inputs = [_]c.wasmtime_val{
            wasmtime.val(.{ .i32 = std.math.cast(i32, len) orelse return null }),
            wasmtime.val(.{ .i32 = ptr_align }), // XXX is ptr_align valid inside WASM runtime?
        };
        defer for (&inputs) |*input| c.wasmtime_val_delete(input);

        var output: c.wasmtime_val = undefined;
        defer c.wasmtime_val_delete(&output);

        {
            var trap: ?*c.wasm_trap_t = null;
            const err = c.wasmtime_func_call(self.memory.wasm_context, &self.wasm_fn_alloc, &inputs, inputs.len, &output, 1, &trap);
            if (err != null or trap != null) return null;
        }

        if (output.kind != c.WASMTIME_I32) {
            std.log.warn(export_names[0] ++ "() returned unexpected type: {}", .{output});
            return null;
        }

        return self.memory.slice()[@intCast(output.of.i32)..].ptr;
    }

    fn resize(self: *const @This(), buf: []u8, buf_align: u8, new_len: usize, _: usize) bool {
        var inputs = [_]c.wasmtime_val{
            wasmtime.val(.{ .i32 = @intCast(self.memory.offset(buf.ptr)) }),
            wasmtime.val(.{ .i32 = @intCast(buf.len) }),
            wasmtime.val(.{ .i32 = buf_align }), // XXX is buf_align valid inside WASM runtime?
            wasmtime.val(.{ .i32 = @intCast(new_len) }),
        };
        defer for (&inputs) |*input| c.wasmtime_val_delete(input);

        var output: c.wasmtime_val = undefined;
        defer c.wasmtime_val_delete(&output);

        {
            var trap: ?*c.wasm_trap_t = null;
            const err = c.wasmtime_func_call(self.memory.wasm_context, &self.wasm_fn_resize, &inputs, inputs.len, &output, 1, &trap);
            if (err != null or trap != null) return false;
        }

        if (output.kind != c.WASMTIME_I32) {
            std.log.warn(export_names[1] ++ "() returned unexpected type: {}", .{output});
            return false;
        }

        return output.of.i32 == 1;
    }

    fn free(self: *const @This(), buf: []u8, buf_align: u8, _: usize) void {
        var inputs = [_]c.wasmtime_val{
            wasmtime.val(.{ .i32 = @intCast(self.memory.offset(buf.ptr)) }),
            wasmtime.val(.{ .i32 = @intCast(buf.len) }),
            wasmtime.val(.{ .i32 = buf_align }), // XXX is buf_align valid inside WASM runtime?
        };
        defer for (&inputs) |*input| c.wasmtime_val_delete(input);

        {
            var trap: ?*c.wasm_trap_t = null;
            const err = c.wasmtime_func_call(self.memory.wasm_context, &self.wasm_fn_free, &inputs, inputs.len, null, 0, &trap);
            if (err != null or trap != null) std.log.warn(export_names[2] ++ "() failed, this likely leaked wasm memory", .{});
        }
    }
};

pub fn linearMemoryAllocator(self: @This()) !Allocator {
    return Allocator.initFromInstance(try Memory.initFromInstance(self.wasm_instance, self.wasm_context), self.wasm_instance);
}

fn handleExit(err: ?*c.wasmtime_error, trap: ?*c.wasm_trap_t) !?c_int {
    if (err) |e| {
        var exit_status: c_int = undefined;
        if (c.wasmtime_error_exit_status(e, &exit_status))
            return exit_status;
    }

    try handleError("failed to call function", err, trap);

    return null;
}

pub fn main(self: @This()) !bool {
    return self.call("_start", &.{}, &.{});
}

pub fn call(self: @This(), func_name: [:0]const u8, inputs: []const wasm.Value, outputs: []wasm.Value) !bool {
    std.log.debug("calling plugin \"{s}\" function \"{s}\"", .{ self.plugin_name, func_name });

    if (self.wasi_config) |wc| try self.configureWasi(wc.*);

    const wasi_collect: ?WasiConfig.CollectOutput = if (self.wasi_config) |wc| blk: {
        if (!comptime std.log.defaultLogEnabled(.debug)) break :blk null;

        if (wc.stdout != null and wc.stdout.? == .inherit or
            wc.stderr != null and wc.stderr.? == .inherit)
        {
            std.log.debug("cannot capture WASI output because stdout or stderr is inherited", .{});
            break :blk null;
        }

        var wasi_config = wc.*;
        const collect = try wasi_config.collectOutput(self.allocator);
        try self.configureWasi(wasi_config);
        break :blk collect;
    } else null;
    defer if (wasi_collect) |wc| wc.deinit();

    const c_inputs = try self.allocator.alloc(c.wasmtime_val, inputs.len);
    for (c_inputs, inputs) |*c_input, input| c_input.* = wasmtime.val(input);
    defer {
        for (c_inputs) |*c_input| c.wasmtime_val_delete(c_input);
        self.allocator.free(c_inputs);
    }

    const c_outputs = try self.allocator.alloc(c.wasmtime_val, outputs.len);
    defer {
        for (c_outputs) |*c_output| c.wasmtime_val_delete(c_output);
        self.allocator.free(c_outputs);
    }

    var func_export: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_instance_export_get(self.wasm_context, &self.wasm_instance, func_name, func_name.len, &func_export)) return error.NoSuchItem;
    defer c.wasmtime_extern_delete(&func_export);
    if (func_export.kind != c.WASMTIME_EXTERN_FUNC) return error.NotAFunction;

    var trap: ?*c.wasm_trap_t = null;
    const wasmtime_err = c.wasmtime_func_call(
        self.wasm_context,
        &func_export.of.func,
        c_inputs.ptr,
        c_inputs.len,
        c_outputs.ptr,
        c_outputs.len,
        &trap,
    );

    for (outputs, c_outputs) |*output, *c_output| output.* = wasmtime.fromVal(c_output) catch |err| switch (err) {
        error.UnknownWasmtimeVal => return false,
    };

    if (wasi_collect) |wc| {
        const wasi_output = try wc.collect(std.math.maxInt(usize));
        defer wasi_output.deinit();

        std.log.debug("stdout: {s}\nstderr: {s}", .{ wasi_output.stdout, wasi_output.stderr });
    }

    if (try handleExit(wasmtime_err, trap)) |exit_status| {
        std.log.debug("exit status: {?d}", .{exit_status});
        return exit_status == 0;
    }

    return true;
}

fn handleError(
    message: []const u8,
    err: ?*c.wasmtime_error,
    trap: ?*c.wasm_trap_t,
) !void {
    if (err == null and trap == null) return;

    var error_message: c.wasm_byte_vec_t = undefined;
    c.wasm_byte_vec_new_empty(&error_message);
    defer c.wasm_byte_vec_delete(&error_message);

    if (err) |e| {
        defer c.wasmtime_error_delete(e);
        c.wasmtime_error_message(e, &error_message);
        std.log.err("{s}: WASM error: {s}", .{ message, error_message.data });
        return error.WasmError;
    }

    if (trap) |t| {
        defer c.wasm_trap_delete(t);
        c.wasm_trap_message(t, &error_message);
        std.log.err("{s}: WASM trap: {s}", .{ message, error_message.data });
        return error.WasmTrap; // TODO decode wasm_trap_code
    }

    unreachable;
}
