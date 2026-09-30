const std = @import("std");
const fsutil = @import("../util/fsutil.zig");
const ju = @import("../util/jsonutil.zig");
const timefmt = @import("../util/timefmt.zig");
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

        var dir = std.Io.Dir.openDir(.cwd(), self.config.io, volumes_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound or err == error.AccessDenied) return;
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
        const content = std.Io.Dir.cwd().readFileAlloc(self.config.io, opts_path, self.allocator, .limited(1024 * 1024)) catch return vol;
        defer self.allocator.free(content);
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, content, .{}) catch return vol;
        defer parsed.deinit();
        const root = ju.object(parsed.value) orelse return vol;

        if (ju.str(root.get("CreatedAt"))) |v| vol.created = @intCast(timefmt.parseRfc3339(v) orelse 0);
        if (ju.int(root.get("CreatedAt"))) |v| vol.created = v;
        if (ju.str(root.get("Driver"))) |v| vol.driver = try self.allocator.dupe(u8, v);
        for ([_]struct { []const u8, *std.StringHashMap([]const u8) }{ .{ "Labels", &vol.labels }, .{ "Options", &vol.options } }) |pair| {
            const obj = ju.object(root.get(pair[0])) orelse continue;
            var it = obj.iterator();
            while (it.next()) |e| {
                const val = ju.str(e.value_ptr.*) orelse continue;
                try pair[1].put(try self.allocator.dupe(u8, e.key_ptr.*), try self.allocator.dupe(u8, val));
            }
        }

        return vol;
    }

    pub fn saveVolumeToDisk(self: *VolumeService, vol: *const Volume) !void {
        var path_buf: [512]u8 = undefined;
        const opts_path = try std.fmt.bufPrint(&path_buf, "{s}/volumes/{s}/opts.json", .{ self.config.data_root, vol.name });
        try fsutil.writeJsonAtomic(self.config.io, self.allocator, opts_path, vol.*);
    }

    pub fn createVolume(self: *VolumeService, name: []const u8, driver: ?[]const u8, labels: ?std.StringHashMap([]const u8), options: ?std.StringHashMap([]const u8)) !*Volume {
        self.lock.lockUncancelable(self.config.io);
        defer self.lock.unlock(self.config.io);

        if (self.by_name.contains(name)) return error.VolumeAlreadyExists;

        var vol_dir_buf: [512]u8 = undefined;
        const vol_dir = try std.fmt.bufPrint(&vol_dir_buf, "{s}/volumes/{s}", .{ self.config.data_root, name });
        std.Io.Dir.createDirAbsolute(self.config.io, vol_dir, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        var data_dir_buf: [512]u8 = undefined;
        const data_dir = try std.fmt.bufPrint(&data_dir_buf, "{s}/volumes/{s}/_data", .{ self.config.data_root, name });
        std.Io.Dir.createDirAbsolute(self.config.io, data_dir, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const vol = try self.allocator.create(Volume);
        errdefer self.allocator.destroy(vol);

        vol.name = try self.allocator.dupe(u8, name);
        vol.driver = try self.allocator.dupe(u8, driver orelse "local");
        vol.mountpoint = try self.allocator.dupe(u8, data_dir);

        const now = std.Io.Clock.now(.real, self.config.io).toNanoseconds();
        vol.created = @intCast(now);
        vol.labels = std.StringHashMap([]const u8).init(self.allocator);
        vol.options = std.StringHashMap([]const u8).init(self.allocator);
        vol.scope = "local";

        if (labels) |l| {
            var it = l.iterator();
            while (it.next()) |entry| {
                const k = try self.allocator.dupe(u8, entry.key_ptr.*);
                const v = try self.allocator.dupe(u8, entry.value_ptr.*);
                try vol.labels.put(k, v);
            }
        }

        if (options) |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                const k = try self.allocator.dupe(u8, entry.key_ptr.*);
                const v = try self.allocator.dupe(u8, entry.value_ptr.*);
                try vol.options.put(k, v);
            }
        }

        try self.by_name.put(vol.name, vol);
        try self.saveVolumeToDisk(vol);

        return vol;
    }

    pub fn deleteVolume(self: *VolumeService, name: []const u8, force: bool) !void {
        _ = force;
        self.lock.lockUncancelable(self.config.io);
        defer self.lock.unlock(self.config.io);

        const vol = self.by_name.get(name) orelse return error.VolumeNotFound;

        var opts_buf: [512]u8 = undefined;
        const opts_path = try std.fmt.bufPrint(&opts_buf, "{s}/volumes/{s}/opts.json", .{ self.config.data_root, name });
        std.Io.Dir.deleteFileAbsolute(self.config.io, opts_path) catch {};

        var data_dir_buf: [512]u8 = undefined;
        const data_dir = try std.fmt.bufPrint(&data_dir_buf, "{s}/volumes/{s}/_data", .{ self.config.data_root, name });
        std.Io.Dir.deleteDirAbsolute(self.config.io, data_dir) catch {};

        var vol_dir_buf: [512]u8 = undefined;
        const vol_dir = try std.fmt.bufPrint(&vol_dir_buf, "{s}/volumes/{s}", .{ self.config.data_root, name });
        std.Io.Dir.deleteDirAbsolute(self.config.io, vol_dir) catch {};

        _ = self.by_name.remove(name);

        self.allocator.free(vol.name);
        self.allocator.free(vol.driver);
        self.allocator.free(vol.mountpoint);
        
        var label_it = vol.labels.iterator();
        while (label_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        vol.labels.deinit();

        var opts_it = vol.options.iterator();
        while (opts_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        vol.options.deinit();

        self.allocator.destroy(vol);
    }
};
