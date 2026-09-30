const std = @import("std");

pub const OverlayLayer = struct {
    id: []const u8,
    data_root: []const u8,

    fn diffPath(self: *const OverlayLayer, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "{s}/overlay2/{s}/diff", .{ self.data_root, self.id }) catch unreachable;
    }
    fn workPath(self: *const OverlayLayer, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "{s}/overlay2/{s}/work", .{ self.data_root, self.id }) catch unreachable;
    }
    fn mergedPath(self: *const OverlayLayer, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "{s}/overlay2/{s}/merged", .{ self.data_root, self.id }) catch unreachable;
    }
    fn lowerPath(self: *const OverlayLayer, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "{s}/overlay2/{s}/lower", .{ self.data_root, self.id }) catch unreachable;
    }
};

/// Mount the overlay filesystem for a container.
pub fn mount(io: std.Io, data_root: []const u8, container_id: []const u8, allocator: std.mem.Allocator) !void {
    var buf: [4096]u8 = undefined;

    const lower_path = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/lower", .{ data_root, container_id });
    // In our project, if lower file doesn't exist, we might not have a lower chain (scratch container).
    // But if it's an image layer, we read it.
    const lower = std.Io.Dir.cwd().readFileAlloc(io, lower_path, allocator, @enumFromInt(@as(usize, 4096))) catch |err| {
        if (err == error.FileNotFound) {
            // No lower layer
            const upper = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/diff", .{ data_root, container_id });
            const work = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/work", .{ data_root, container_id });
            const merged = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/merged", .{ data_root, container_id });

            var opts_buf: [8192]u8 = undefined;
            const opts = try std.fmt.bufPrint(&opts_buf, "upperdir={s},workdir={s}", .{ upper, work });

            try runCmd(io, allocator, &.{ "mount", "-t", "overlay", "overlay", "-o", opts, merged });
            return;
        }
        return err;
    };
    defer allocator.free(lower);

    // Expand l/ symlinks to full paths
    var lower_full_buf: [4096]u8 = undefined;
    const lower_full = try expandLowerPaths(data_root, lower, &lower_full_buf);

    const upper = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/diff", .{ data_root, container_id });
    const work = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/work", .{ data_root, container_id });
    const merged = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/merged", .{ data_root, container_id });

    // Build mount options: "lowerdir=...,upperdir=...,workdir=..."
    var opts_buf: [8192]u8 = undefined;
    const opts = try std.fmt.bufPrint(&opts_buf, "lowerdir={s},upperdir={s},workdir={s}", .{ lower_full, upper, work });

    // Execute: mount -t overlay overlay -o {opts} {merged}
    try runCmd(io, allocator, &.{ "mount", "-t", "overlay", "overlay", "-o", opts, merged });
}

/// Unmount the overlay filesystem.
pub fn unmount(io: std.Io, data_root: []const u8, container_id: []const u8, allocator: std.mem.Allocator) !void {
    var buf: [512]u8 = undefined;
    const merged = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/merged", .{ data_root, container_id });
    runCmd(io, allocator, &.{ "umount", merged }) catch |err| {
        std.log.warn("umount failed: {}", .{err});
    };
}

fn expandLowerPaths(data_root: []const u8, lower: []const u8, buf: []u8) ![]u8 {
    // "l/ABCD:l/EFGH" → "{data_root}/overlay2/l/ABCD:{data_root}/overlay2/l/EFGH"
    var pos: usize = 0;
    var it = std.mem.splitScalar(u8, lower, ':');
    var first = true;
    while (it.next()) |segment| {
        const clean_seg = std.mem.trim(u8, segment, " \r\n");
        if (clean_seg.len == 0) continue;
        if (!first) {
            if (pos >= buf.len) return error.NoSpaceLeft;
            buf[pos] = ':';
            pos += 1;
        }
        const written = try std.fmt.bufPrint(buf[pos..], "{s}/overlay2/{s}", .{ data_root, clean_seg });
        pos += written.len;
        first = false;
    }
    return buf[0..pos];
}

fn runCmd(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var proc = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    // Drain stderr before waiting: wait() releases the pipe.
    var read_buf: [1024]u8 = undefined;
    var reader = proc.stderr.?.reader(io, &read_buf);
    const stderr_content = reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch "";
    defer if (stderr_content.len > 0) allocator.free(stderr_content);

    const term = try proc.wait(io);
    if (term != .exited or term.exited != 0) {
        std.log.err("{s} failed: {s}", .{ argv[0], std.mem.trim(u8, stderr_content, " \n") });
        return error.CommandFailed;
    }
}
