const std = @import("std");
const DaemonConfig = @import("../config/config.zig").DaemonConfig;
const Volume = @import("types.zig").Volume;

pub const VolumeService = struct {
    allocator: std.mem.Allocator,
    config: DaemonConfig,
    by_name: std.StringHashMap(*Volume),
    lock: std.Io.RwLock = .init,

    pub fn init(allocator: std.mem.Allocator, config: DaemonConfig) !VolumeService {
        var svc = VolumeService{
            .allocator = allocator,
            .config = config,
            .by_name = std.StringHashMap(*Volume).init(allocator),
        };
        try svc.loadFromDisk();
        return svc;
    }

    pub fn deinit(self: *VolumeService) void {
        self.by_name.deinit();
    }

    pub fn get(self: *VolumeService, name: []const u8) ?*Volume {
        self.lock.lockSharedUncancelable(self.config.io);
        defer self.lock.unlockShared(self.config.io);
        return self.by_name.get(name);
    }

    pub fn list(self: *VolumeService, allocator: std.mem.Allocator) ![]*Volume {
        self.lock.lockSharedUncancelable(self.config.io);
        defer self.lock.unlockShared(self.config.io);

        var result = try std.ArrayList(*Volume).initCapacity(allocator, self.by_name.count());
        var it = self.by_name.valueIterator();
        while (it.next()) |vol| result.appendAssumeCapacity(vol.*);
        return try result.toOwnedSlice(allocator);
    }

    fn loadFromDisk(self: *VolumeService) !void {
        var path_buf: [512]u8 = undefined;
        const volumes_dir = try std.fmt.bufPrint(&path_buf, "{s}/volumes", .{self.config.data_root});

        var dir = std.Io.Dir.openDirAbsolute(self.config.io, volumes_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.close(self.config.io);

        var it = dir.iterate();
        while (try it.next(self.config.io)) |entry| {
            if (entry.kind != .directory) continue;

            var opts_path_buf: [512]u8 = undefined;
            const opts_path = try std.fmt.bufPrint(&opts_path_buf, "{s}/volumes/{s}/opts.json", .{ self.config.data_root, entry.name });

            const vol = self.loadVolumeFromFile(entry.name, opts_path) catch |err| {
                std.log.warn("failed to load volume {s}: {}", .{ entry.name, err });
                continue;
            };

            try self.by_name.put(vol.name, vol);
        }
    }

    fn loadVolumeFromFile(self: *VolumeService, name: []const u8, opts_path: []const u8) !*Volume {
        const vol = try self.allocator.create(Volume);
        errdefer self.allocator.destroy(vol);

        var mountpoint_buf: [512]u8 = undefined;
        const mountpoint = try std.fmt.bufPrint(&mountpoint_buf, "{s}/volumes/{s}/_data", .{ self.config.data_root, name });

        vol.name = try self.allocator.dupe(u8, name);
        vol.driver = "local";
        vol.mountpoint = try self.allocator.dupe(u8, mountpoint);
        vol.created = 0;
        vol.labels = std.StringHashMap([]const u8).init(self.allocator);
        vol.options = std.StringHashMap([]const u8).init(self.allocator);
        vol.scope = "local";

        // opts.json is optional — absence is not a failure
        const file = std.Io.Dir.openFileAbsolute(self.config.io, opts_path, .{}) catch return vol;
        defer file.close(self.config.io);

        var read_buf: [4096]u8 = undefined;
        var file_reader = file.reader(self.config.io, &read_buf);
        const content = file_reader.interface.allocRemaining(self.allocator, std.Io.Limit.limited(1 * 1024 * 1024)) catch return vol;
        defer self.allocator.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, content, .{}) catch return vol;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return vol,
        };

        if (root.get("CreatedAt")) |v| vol.created = v.integer;
        if (root.get("Driver")) |v| vol.driver = try self.allocator.dupe(u8, v.string);

        if (root.get("Labels")) |v| {
            if (v == .object) {
                var label_it = v.object.iterator();
                while (label_it.next()) |entry| {
                    const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                    const val = try self.allocator.dupe(u8, entry.value_ptr.*.string);
                    try vol.labels.put(key, val);
                }
            }
        }

        if (root.get("Options")) |v| {
            if (v == .object) {
                var opts_it = v.object.iterator();
                while (opts_it.next()) |entry| {
                    const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                    const val = try self.allocator.dupe(u8, entry.value_ptr.*.string);
                    try vol.options.put(key, val);
                }
            }
        }

        return vol;
    }
};
