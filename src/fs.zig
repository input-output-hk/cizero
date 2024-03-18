const std = @import("std");

const known_folders = @import("known-folders");

pub const TmpFile = struct {
    path: []const u8,
    file: std.fs.File,

    /// Deletes the file.
    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        self.file.close();

        std.fs.deleteFileAbsolute(self.path) catch |err|
            std.log.err("could not delete temporary file \"{s}\": {s}", .{ self.path, @errorName(err) });

        alloc.free(self.path);
    }
};

pub fn tmpFile(allocator: std.mem.Allocator, options: struct {
    mode: std.fs.File.Mode = std.fs.File.default_mode,
    read: bool = false,
    max_tmp_files: u8 = 50,
}) !TmpFile {
    const known_path = try known_folders.getPath(allocator, .cache) orelse return error.NoTmpParentDir;
    defer allocator.free(known_path);

    var known_dir = try std.fs.openDirAbsolute(known_path, .{});
    defer known_dir.close();

    const sub_path = try std.fs.path.join(allocator, &.{ "cizero", "tmp" });
    defer allocator.free(sub_path);

    var tmp_dir = try known_dir.makeOpenPath(sub_path, .{});
    defer tmp_dir.close();

    for (0..options.max_tmp_files) |i| {
        const name = try std.fmt.allocPrint(allocator, "{d}-{d}", .{ std.Thread.getCurrentId(), i });
        defer allocator.free(name);

        const file = tmp_dir.createFile(name, .{
            .exclusive = true,
            .mode = options.mode,
            .read = options.read,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };

        return .{
            .path = try std.fs.path.join(allocator, &.{ known_path, sub_path, name }),
            .file = file,
        };
    }

    return error.AllTmpFilesBusy;
}

pub fn pluginDataDirPathZ(allocator: std.mem.Allocator, plugin_name: []const u8) ![:0]const u8 {
    const known_path = try known_folders.getPath(allocator, .data) orelse return error.NoKnownDataDir;
    defer allocator.free(known_path);

    const dir_name = try allocator.alloc(u8, std.fs.base64_encoder.calcSize(plugin_name.len));
    defer allocator.free(dir_name);
    std.debug.assert(std.fs.base64_encoder.encode(dir_name, plugin_name).len == dir_name.len);

    return std.fs.path.joinZ(allocator, &.{ known_path, "cizero", "plugins", dir_name });
}
