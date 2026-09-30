//! Resolves Docker `--user` strings ("uid", "uid:gid", "name", "name:group")
//! against the container rootfs's /etc/passwd and /etc/group.
const std = @import("std");

pub const Ids = struct { uid: u32, gid: u32 };

pub fn resolve(io: std.Io, allocator: std.mem.Allocator, rootfs: []const u8, spec: []const u8) !Ids {
    if (spec.len == 0) return .{ .uid = 0, .gid = 0 };
    const colon = std.mem.indexOfScalar(u8, spec, ':');
    const user_part = spec[0 .. colon orelse spec.len];
    const group_part: ?[]const u8 = if (colon) |c| spec[c + 1 ..] else null;

    var ids: Ids = undefined;
    if (std.fmt.parseInt(u32, user_part, 10)) |uid| {
        // Numeric uid: primary gid from passwd if the uid is listed, else 0 (as Docker does).
        ids = .{ .uid = uid, .gid = (try lookup(io, allocator, rootfs, "/etc/passwd", user_part, true)) orelse 0 };
    } else |_| {
        const entry = try lookupEntry(io, allocator, rootfs, "/etc/passwd", user_part, false) orelse return error.UserNotFound;
        ids = .{ .uid = entry[0], .gid = entry[1] };
    }

    if (group_part) |g| {
        ids.gid = std.fmt.parseInt(u32, g, 10) catch
            (try lookupEntry(io, allocator, rootfs, "/etc/group", g, false) orelse return error.GroupNotFound)[0];
    }
    return ids;
}

/// Primary gid of the passwd entry whose uid field equals `key`.
fn lookup(io: std.Io, allocator: std.mem.Allocator, rootfs: []const u8, file: []const u8, key: []const u8, by_id: bool) !?u32 {
    const entry = try lookupEntry(io, allocator, rootfs, file, key, by_id) orelse return null;
    return entry[1];
}

/// Returns fields 3 and 4 (id, gid) of the first line matching `key` on
/// field 1 (name) or, if `by_id`, field 3.
fn lookupEntry(io: std.Io, allocator: std.mem.Allocator, rootfs: []const u8, file: []const u8, key: []const u8, by_id: bool) !?[2]u32 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ rootfs, file });
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);
    return parseEntry(content, key, by_id);
}

fn parseEntry(content: []const u8, key: []const u8, by_id: bool) ?[2]u32 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next(); // password
        const id_str = fields.next() orelse continue;
        const gid_str = fields.next() orelse "";
        if (!std.mem.eql(u8, if (by_id) id_str else name, key)) continue;
        const id = std.fmt.parseInt(u32, id_str, 10) catch continue;
        const gid = std.fmt.parseInt(u32, gid_str, 10) catch id; // /etc/group has no 4th numeric field
        return .{ id, gid };
    }
    return null;
}

test "parseEntry finds users by name and id" {
    const passwd = "root:x:0:0:root:/root:/bin/sh\nnginx:x:101:102:nginx:/:/sbin/nologin\n";
    try std.testing.expectEqual([2]u32{ 101, 102 }, parseEntry(passwd, "nginx", false).?);
    try std.testing.expectEqual([2]u32{ 101, 102 }, parseEntry(passwd, "101", true).?);
    try std.testing.expectEqual(null, parseEntry(passwd, "nobody", false));
    const group = "wheel:x:10:root\n";
    try std.testing.expectEqual(@as(u32, 10), parseEntry(group, "wheel", false).?[0]);
}
