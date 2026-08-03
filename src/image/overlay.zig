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

/// Create the directory structure for a new read-only image layer.
pub fn createReadOnlyLayer(io: std.Io, data_root: []const u8, layer_id: []const u8, parent_id: ?[]const u8, allocator: std.mem.Allocator) !void {
    var buf: [512]u8 = undefined;

    // Create diff/, link file, and symlink in l/ directory
    const diff = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/diff", .{ data_root, layer_id });
    try std.Io.Dir.createDirAbsolute(io, diff, .default_dir);

    // Generate a short name for the l/ symlink directory
    var short: [26]u8 = undefined;
    generateShortName(&short);

    const link_path = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/link", .{ data_root, layer_id });
    var link_file = try std.Io.Dir.createFileAbsolute(io, link_path, .{});
    defer link_file.close(io);
    var write_buf: [32]u8 = undefined;
    try link_file.writer(io, &write_buf).writeAll(&short);

    const symlink_path = try std.fmt.bufPrint(&buf, "{s}/overlay2/l/{s}", .{ data_root, short });
    const target = try std.fmt.bufPrint(&buf, "../{s}/diff", .{layer_id});
    try std.Io.Dir.symLinkAbsolute(io, target, symlink_path, .{});

    // If there's a parent, build the 'lower' chain
    if (parent_id) |pid| {
        const parent_link_path = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/link", .{ data_root, pid });
        var parent_link_file = try std.Io.Dir.openFileAbsolute(io, parent_link_path, .{ .mode = .read_only });
        var read_buf: [64]u8 = undefined;
        const parent_short = try parent_link_file.reader(io, &read_buf).interface.readAlloc(allocator, 64);
        defer allocator.free(parent_short);
        parent_link_file.close(io);

        const parent_lower_path = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/lower", .{ data_root, pid });
        const parent_lower = std.Io.Dir.cwd().readFileAlloc(io, parent_lower_path, allocator, @enumFromInt(@as(usize, 4096))) catch |err| blk: {
            if (err == error.FileNotFound) break :blk &[_]u8{};
            return err;
        };
        defer if (parent_lower.len > 0) allocator.free(parent_lower);

        const lower_path = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/lower", .{ data_root, layer_id });
        var lower_file = try std.Io.Dir.createFileAbsolute(io, lower_path, .{});
        defer lower_file.close(io);

        var lower_write_buf: [128]u8 = undefined;
        var lower_writer = lower_file.writer(io, &lower_write_buf);
        if (parent_lower.len > 0) {
            try lower_writer.interface.print("l/{s}:l/{s}", .{ parent_short, parent_lower });
        } else {
            try lower_writer.interface.print("l/{s}", .{parent_short});
        }
    }
}

/// Create a writable layer for a container.
pub fn createWritableLayer(io: std.Io, data_root: []const u8, container_id: []const u8, top_image_layer_id: []const u8, allocator: std.mem.Allocator) !void {
    var buf: [512]u8 = undefined;

    // Create diff/, work/, merged/ directories
    for ([_][]const u8{ "diff", "work", "merged" }) |subdir| {
        const path = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/{s}", .{ data_root, container_id, subdir });
        try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
    }

    try createReadOnlyLayer(io, data_root, container_id, top_image_layer_id, allocator);
}

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

fn generateShortName(out: *[26]u8) void {
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var rng = std.rand.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    for (out) |*c| c.* = chars[rng.random().intRangeLessThan(u8, 0, chars.len)];
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
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const term = try proc.wait(io);
    if (term != .exited or term.exited != 0) {
        if (proc.stderr) |*r| {
            var read_buf: [1024]u8 = undefined;
            var reader = r.reader(io, &read_buf);
            const stderr_content = try reader.interface.allocRemaining(allocator, .unlimited);
            defer allocator.free(stderr_content);
            std.log.err("command failed: {s}", .{stderr_content});
        }
        return error.CommandFailed;
    }
}
