const std = @import("std");
const DaemonConfig = @import("../config/config.zig").DaemonConfig;
const Image = @import("types.zig").Image;
const ImageConfig = @import("types.zig").ImageConfig;
const RootFS = @import("types.zig").RootFS;

pub const LoadError = error{
    InvalidJson,
    MissingId,
};

pub const ImageService = struct {
    allocator: std.mem.Allocator,
    config: DaemonConfig,
    by_id: std.StringHashMap(*Image),
    lock: std.Io.RwLock = .{},

    pub fn init(allocator: std.mem.Allocator, config: DaemonConfig) !ImageService {
        var svc = ImageService{
            .allocator = allocator,
            .config = config,
            .by_id = std.StringHashMap(*Image).init(allocator),
        };
        try svc.loadFromDisk();
        return svc;
    }

    pub fn deinit(self: *ImageService) void {
        self.by_id.deinit();
    }

    pub fn get(self: *ImageService, id: []const u8) ?*Image {
        self.lock.lockShared(self.config.io);
        defer self.lock.unlockShared(self.config.io);
        return self.by_id.get(id);
    }

    pub fn list(self: *ImageService, allocator: std.mem.Allocator) ![]*Image {
        self.lock.lockShared(self.config.io);
        defer self.lock.unlockShared(self.config.io);

        var result = try std.ArrayList(*Image).initCapacity(allocator, self.by_id.count());
        var it = self.by_id.valueIterator();
        while (it.next()) |img| result.appendAssumeCapacity(img.*);
        return try result.toOwnedSlice();
    }

    fn loadFromDisk(self: *ImageService) !void {
        var path_buf: [512]u8 = undefined;
        const images_dir = try std.fmt.bufPrint(&path_buf, "{s}/image/overlay2/imagedb/content/sha256", .{self.config.data_root});

        var dir = std.Io.Dir.openDirAbsolute(self.config.io, images_dir, .{ .iterate = true }) catch |err| {
            if (err == std.Io.Dir.OpenError.FileNotFound) return;
            return err;
        };
        defer dir.close(self.config.io);

        var it = dir.iterate();
        while (try it.next(self.config.io)) |entry| {
            if (entry.kind != .file) continue;

            var img_path_buf: [512]u8 = undefined;
            const img_path = try std.fmt.bufPrint(&img_path_buf, "{s}/image/overlay2/imagedb/content/sha256/{s}", .{ self.config.data_root, entry.name });

            const img = self.loadImageFromFile(img_path) catch |err| {
                std.log.warn("failed to load image {s}: {}", .{ entry.name, err });
                continue;
            };

            try self.by_id.put(img.id, img);
        }
    }

    fn loadImageFromFile(self: *ImageService, path: []const u8) !*Image {
        const file = try std.Io.Dir.openFileAbsolute(self.config.io, path, .{});
        defer file.close(self.config.io);

        var read_buf: [4096]u8 = undefined;
        const content = try file.reader(self.config.io, &read_buf).readAllAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return LoadError.InvalidJson,
        };

        const img = try self.allocator.create(Image);
        errdefer self.allocator.destroy(img);

        img.id = try self.allocator.dupe(u8, (root.get("Id") orelse return LoadError.MissingId).string);
        img.created = if (root.get("Created")) |v| v.integer else 0;
        img.size = if (root.get("Size")) |v| v.integer else 0;
        img.architecture = try self.allocator.dupe(u8, if (root.get("Architecture")) |v| v.string else "amd64");
        img.os = try self.allocator.dupe(u8, if (root.get("Os")) |v| v.string else "linux");
        img.repo_tags = if (root.get("RepoTags")) |v| try parseStringSlice(v, self.allocator) else &.{};
        img.repo_digests = if (root.get("RepoDigests")) |v| try parseStringSlice(v, self.allocator) else &.{};

        img.rootfs = .{ .layers = &.{} };
        if (root.get("RootFS")) |rfs| {
            if (rfs == .object) {
                if (rfs.object.get("Layers")) |layers| {
                    img.rootfs.layers = try parseStringSlice(layers, self.allocator);
                }
            }
        }

        img.config = .{
            .exposesd_ports = std.StringHashMap(void).init(self.allocator),
        };

        return img;
    }
};

fn parseStringSlice(val: std.json.Value, allocator: std.mem.Allocator) ![][]const u8 {
    const arr = switch (val) {
        .array => |a| a,
        else => return &.{},
    };
    const result = try allocator.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        result[i] = try allocator.dupe(u8, item.string);
    }
    return result;
}
