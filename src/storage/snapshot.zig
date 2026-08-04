const std = @import("std");
const DaemonConfig = @import("../config/config.zig").DaemonConfig;
const OverlayDriver = @import("overlay.zig").OverlayDriver;

pub const Snapshot = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    snapshot_path: []const u8,
    created_at: i64,
};

pub const SnapshotManager = struct {
    allocator: std.mem.Allocator,
    config: DaemonConfig,
    snapshots: std.StringHashMap(Snapshot),
    lock: std.Io.RwLock = .init,

    pub fn init(allocator: std.mem.Allocator, config: DaemonConfig) SnapshotManager {
        return .{
            .allocator = allocator,
            .config = config,
            .snapshots = std.StringHashMap(Snapshot).init(allocator),
        };
    }

    pub fn deinit(self: *SnapshotManager) void {
        var it = self.snapshots.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.id);
            if (entry.value_ptr.parent_id) |p| self.allocator.free(p);
            self.allocator.free(entry.value_ptr.snapshot_path);
        }
        self.snapshots.deinit();
    }

    pub fn createSnapshot(self: *SnapshotManager, id: []const u8, parent_id: ?[]const u8, upper_diff_path: []const u8) !Snapshot {
        self.lock.lockUncancelable(self.config.io);
        defer self.lock.unlock(self.config.io);

        var path_buf: [512]u8 = undefined;
        const target_dir = try std.fmt.bufPrint(&path_buf, "{s}/snapshots/{s}", .{ self.config.data_root, id });

        std.Io.Dir.createDirAbsolute(self.config.io, target_dir, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists and err != error.AccessDenied) return err;
        };

        const dup_id = try self.allocator.dupe(u8, id);
        const dup_parent = if (parent_id) |p| try self.allocator.dupe(u8, p) else null;
        const dup_path = try self.allocator.dupe(u8, target_dir);

        const snap = Snapshot{
            .id = dup_id,
            .parent_id = dup_parent,
            .snapshot_path = dup_path,
            .created_at = std.time.timestamp(),
        };

        try self.snapshots.put(dup_id, snap);

        _ = upper_diff_path;
        return snap;
    }

    pub fn getLowerDirs(self: *SnapshotManager, allocator: std.mem.Allocator, id: []const u8) ![]const []const u8 {
        self.lock.lockSharedUncancelable(self.config.io);
        defer self.lock.unlockShared(self.config.io);

        var list = std.ArrayList([]const u8).empty;
        errdefer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }

        var current_id: ?[]const u8 = id;
        while (current_id) |cid| {
            if (self.snapshots.get(cid)) |snap| {
                try list.append(allocator, try allocator.dupe(u8, snap.snapshot_path));
                current_id = snap.parent_id;
            } else {
                break;
            }
        }

        return try list.toOwnedSlice(allocator);
    }
};

test "snapshot manager chain resolution" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var cfg = DaemonConfig.init(io);
    cfg.data_root = "/tmp/cratezig-snapshot-test";

    var mgr = SnapshotManager.init(alloc, cfg);
    defer mgr.deinit();

    _ = try mgr.createSnapshot("layer1", null, "/tmp");
    _ = try mgr.createSnapshot("layer2", "layer1", "/tmp");

    const lowers = try mgr.getLowerDirs(alloc, "layer2");
    defer {
        for (lowers) |l| alloc.free(l);
        alloc.free(lowers);
    }

    try std.testing.expectEqual(@as(usize, 2), lowers.len);
}
