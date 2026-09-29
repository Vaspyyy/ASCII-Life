//! Native Linux file boundary. The simulation's portable codec owns validation;
//! this module owns bounded reads and durable atomic replacement of a slot.
const std = @import("std");
const persistence = @import("persistence.zig");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
});

pub fn defaultPath(allocator: std.mem.Allocator) ![:0]u8 {
    if (c.getenv("XDG_DATA_HOME")) |p| {
        const root = std.mem.span(p);
        if (root.len > 0 and root[0] == '/') return std.fmt.allocPrintSentinel(allocator, "{s}/ascii-life/life.sav", .{root}, 0);
    }
    const home = c.getenv("HOME") orelse return error.NoHomeDirectory;
    const root = std.mem.span(home);
    if (root.len == 0 or root[0] != '/') return error.NoHomeDirectory;
    return std.fmt.allocPrintSentinel(allocator, "{s}/.local/share/ascii-life/life.sav", .{root}, 0);
}

pub fn read(allocator: std.mem.Allocator, path: [:0]const u8) !?[]u8 {
    const file = c.fopen(path.ptr, "rb") orelse {
        if (c.__errno_location().* == c.ENOENT) return null;
        return error.SaveReadFailed;
    };
    defer _ = c.fclose(file);
    const bytes = try allocator.alloc(u8, persistence.max_file_bytes + 1);
    errdefer allocator.free(bytes);
    const count = c.fread(bytes.ptr, 1, bytes.len, file);
    if (c.ferror(file) != 0) return error.SaveReadFailed;
    if (count > persistence.max_file_bytes) return error.SaveTooLarge;
    return try allocator.realloc(bytes, count);
}

fn ensureParent(path: [:0]const u8) !void {
    if (path.len == 0 or path.len >= 4096) return error.InvalidSavePath;
    var buffer: [4096:0]u8 = undefined;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    for (path, 0..) |ch, index| {
        if (ch != '/' or index == 0) continue;
        buffer[index] = 0;
        if (c.mkdir(&buffer, 0o700) != 0 and c.__errno_location().* != c.EEXIST) return error.SaveDirectoryFailed;
        buffer[index] = '/';
    }
}

pub fn write(path: [:0]const u8, data: []const u8) !void {
    if (data.len > persistence.max_file_bytes) return error.SaveTooLarge;
    try ensureParent(path);
    var parent_buffer: [4096:0]u8 = undefined;
    const parent = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| (if (slash == 0) "/" else path[0..slash]) else ".";
    @memcpy(parent_buffer[0..parent.len], parent);
    parent_buffer[parent.len] = 0;
    const directory = c.open(&parent_buffer, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (directory < 0) return error.SaveDirectoryFailed;
    defer _ = c.close(directory);
    var temp: [4112:0]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&temp, "{s}.tmp.XXXXXX", .{path});
    const fd = c.mkstemp(name.ptr);
    if (fd < 0) return error.SaveWriteFailed;
    const file = c.fdopen(fd, "wb") orelse {
        _ = c.close(fd);
        _ = c.unlink(name.ptr);
        return error.SaveWriteFailed;
    };
    var closed = false;
    defer {
        if (!closed) _ = c.fclose(file);
        _ = c.unlink(name.ptr);
    }
    if (c.fwrite(data.ptr, 1, data.len, file) != data.len or c.fflush(file) != 0 or c.fsync(fd) != 0) return error.SaveWriteFailed;
    const result = c.fclose(file);
    closed = true;
    if (result != 0 or c.rename(name.ptr, path.ptr) != 0) return error.SaveWriteFailed;
    if (c.fsync(directory) != 0) return error.SaveSyncFailed;
}
