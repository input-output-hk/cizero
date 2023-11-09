const std = @import("std");

const known_folders = @import("known-folders");

pub threadlocal var max_tmp_files: u8 = 50;

pub fn tmpPath(allocator: std.mem.Allocator, mode: ?std.fs.File.Mode) !?[]const u8 {
    const result = try tmpFile(allocator, mode, false) orelse return null;
    result.file.close();
    return result.path;
}

pub fn tmpFile(allocator: std.mem.Allocator, mode: ?std.fs.File.Mode, read: bool) !?struct { path: []const u8, file: std.fs.File } {
    return if (try known_folders.getPath(allocator, .cache)) |dir_path| path: {
        defer allocator.free(dir_path);

        var dir = try std.fs.openDirAbsolute(dir_path, .{});
        defer dir.close();

        for (0..max_tmp_files) |i| {
            const sub_path = sub_path: {
                const name = try std.fmt.allocPrint(allocator, "{d}-{d}", .{ std.Thread.getCurrentId(), i });
                defer allocator.free(name);

                break :sub_path try std.fs.path.join(allocator, &.{ "cizero", "tmp", name });
            };
            defer allocator.free(sub_path);

            try dir.makePath(std.fs.path.dirname(sub_path).?);

            const file = dir.createFile(sub_path, .{
                .exclusive = true,
                .mode = mode orelse std.fs.File.default_mode,
                .read = read,
            }) catch |err| if (err == error.PathAlreadyExists) continue else return err;

            break :path .{
                .path = try std.fs.path.join(allocator, &.{ dir_path, sub_path }),
                .file = file,
            };
        }

        return error.AllTmpFilesBusy;
    } else null;
}
