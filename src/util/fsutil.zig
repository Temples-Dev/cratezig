//! Small filesystem helpers shared by every persistence path.
const std = @import("std");

/// Writes `data` to `path` via `<path>.tmp` + fsync + rename, so readers
/// never observe a half-written file even if the daemon crashes mid-write.
pub fn writeFileAtomic(io: std.Io, path: []const u8, data: []const u8) !void {
    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    {
        const file = try std.Io.Dir.createFile(.cwd(), io, tmp, .{});
        defer file.close(io);
        try file.writePositionalAll(io, data, 0);
        try file.sync(io);
    }
    try std.Io.Dir.rename(.cwd(), tmp, .cwd(), path, io);
}

/// Serializes `value` with std.json (so every string is escaped) and writes
/// it atomically.
pub fn writeJsonAtomic(io: std.Io, allocator: std.mem.Allocator, path: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    try writeFileAtomic(io, path, bytes);
}

/// Opens (creating if needed) `path` for appending. Every write, including
/// ones from child processes that inherit the fd, lands at end of file.
pub fn openAppend(path: []const u8) !std.Io.File {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o640);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

test "writeFileAtomic replaces content and leaves no tmp file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/state.json", .{root});
    try writeFileAtomic(io, path, "first-longer-content");
    try writeFileAtomic(io, path, "second");

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("second", content);

    var tmp_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, tmp_path, .{}));
}
