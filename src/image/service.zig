const std = @import("std");
const DaemonConfig = @import("../config/config.zig").DaemonConfig;
pub const Image = @import("types.zig").Image;
const ImageConfig = @import("types.zig").ImageConfig;
const RootFS = @import("types.zig").RootFS;
const CrateError = @import("../errdefs/errors.zig").Error;

pub const LoadError = error{
    InvalidJson,
    MissingId,
};

pub const ImageService = struct {
    allocator: std.mem.Allocator,
    config: DaemonConfig,
    by_id: std.StringHashMap(*Image),
    by_tag: std.StringHashMap(*Image),
    lock: std.Io.RwLock = .init,

    pub fn init(allocator: std.mem.Allocator, config: DaemonConfig) !ImageService {
        var svc = ImageService{
            .allocator = allocator,
            .config = config,
            .by_id = std.StringHashMap(*Image).init(allocator),
            .by_tag = std.StringHashMap(*Image).init(allocator),
        };
        try svc.loadFromDisk();
        return svc;
    }

    pub fn deinit(self: *ImageService) void {
        var it = self.by_id.iterator();
        while (it.next()) |entry| {
            const img = entry.value_ptr.*;
            self.allocator.free(img.id);
            for (img.repo_tags) |t| self.allocator.free(t);
            self.allocator.free(img.repo_tags);
            self.allocator.free(img.architecture);
            self.allocator.free(img.os);
            img.config.exposesd_ports.deinit();
            self.allocator.destroy(img);
        }
        self.by_id.deinit();
        self.by_tag.deinit();
    }

    pub fn get(self: *ImageService, id: []const u8) ?*Image {
        self.lock.lockSharedUncancelable(self.config.io);
        defer self.lock.unlockShared(self.config.io);
        return self.by_id.get(id);
    }

    pub fn getImage(self: *ImageService, id_or_tag: []const u8) !*Image {
        self.lock.lockSharedUncancelable(self.config.io);
        defer self.lock.unlockShared(self.config.io);

        if (self.by_id.get(id_or_tag)) |img| return img;

        var tag_buf: [256]u8 = undefined;
        const tag = if (std.mem.indexOfScalar(u8, id_or_tag, ':') != null)
            id_or_tag
        else
            std.fmt.bufPrint(&tag_buf, "{s}:latest", .{id_or_tag}) catch id_or_tag;

        if (self.by_tag.get(tag)) |img| return img;

        var prefix_match: ?*Image = null;
        var it = self.by_id.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, id_or_tag)) {
                if (prefix_match != null) return CrateError.ImageNotFound;
                prefix_match = entry.value_ptr.*;
            }
        }
        if (prefix_match) |img| return img;

        return CrateError.ImageNotFound;
    }

const overlay = @import("overlay.zig");

    /// Creates an overlay2 writable layer for a container.
    /// Produces: overlay2/{id}/{diff,work}/ and overlay2/{id}/lower.
    pub fn createWritableLayer(self: *ImageService, id: *const [64]u8, image_id: []const u8) !void {
        var layer_buf: [512]u8 = undefined;
        const layer_path = try std.fmt.bufPrint(&layer_buf, "{s}/overlay2/{s}", .{ self.config.data_root, id });

        try std.Io.Dir.createDirAbsolute(self.config.io, layer_path, .default_dir);

        var diff_buf: [530]u8 = undefined;
        try std.Io.Dir.createDirAbsolute(self.config.io, try std.fmt.bufPrint(&diff_buf, "{s}/diff", .{layer_path}), .default_dir);

        var work_buf: [530]u8 = undefined;
        try std.Io.Dir.createDirAbsolute(self.config.io, try std.fmt.bufPrint(&work_buf, "{s}/work", .{layer_path}), .default_dir);

        var lower_path_buf: [530]u8 = undefined;
        const lower_path = try std.fmt.bufPrint(&lower_path_buf, "{s}/lower", .{layer_path});

        const lower_file = try std.Io.Dir.createFileAbsolute(self.config.io, lower_path, .{});
        defer lower_file.close(self.config.io);

        var write_buf: [128]u8 = undefined;
        var lower_writer = lower_file.writer(self.config.io, &write_buf);
        try lower_writer.interface.writeAll(image_id);
    }

    pub fn mountWritableLayer(self: *ImageService, id: []const u8) !void {
        try overlay.mount(self.config.io, self.config.data_root, id, self.allocator);
    }

    pub fn unmountWritableLayer(self: *ImageService, id: []const u8) !void {
        try overlay.unmount(self.config.io, self.config.data_root, id, self.allocator);
    }

    pub fn list(self: *ImageService, allocator: std.mem.Allocator) ![]*Image {
        self.lock.lockSharedUncancelable(self.config.io);
        defer self.lock.unlockShared(self.config.io);

        var result = try std.ArrayList(*Image).initCapacity(allocator, self.by_id.count());
        var it = self.by_id.valueIterator();
        while (it.next()) |img| result.appendAssumeCapacity(img.*);
        return try result.toOwnedSlice(allocator);
    }

    fn loadFromDisk(self: *ImageService) !void {
        var path_buf: [512]u8 = undefined;
        const images_dir = try std.fmt.bufPrint(&path_buf, "{s}/image/overlay2/imagedb/content/sha256", .{self.config.data_root});

        var dir = std.Io.Dir.openDirAbsolute(self.config.io, images_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound or err == error.AccessDenied) return;
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
            for (img.repo_tags) |t| {
                try self.by_tag.put(t, img);
            }
        }
    }

    fn loadImageFromFile(self: *ImageService, path: []const u8) !*Image {
        const file = try std.Io.Dir.openFileAbsolute(self.config.io, path, .{});
        defer file.close(self.config.io);

        var read_buf: [4096]u8 = undefined;
        var file_reader = file.reader(self.config.io, &read_buf);
        const content = try file_reader.interface.allocRemaining(self.allocator, std.Io.Limit.limited(10 * 1024 * 1024));
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

    pub fn saveImageToDisk(self: *ImageService, img: *const Image) !void {
        var hash = img.id;
        if (std.mem.startsWith(u8, hash, "sha256:")) {
            hash = hash[7..];
        }
        var path_buf: [512]u8 = undefined;
        const img_path = try std.fmt.bufPrint(&path_buf, "{s}/image/overlay2/imagedb/content/sha256/{s}", .{ self.config.data_root, hash });

        const file = try std.Io.Dir.createFileAbsolute(self.config.io, img_path, .{});
        defer file.close(self.config.io);

        var write_buf: [4096]u8 = undefined;
        var file_writer = file.writer(self.config.io, &write_buf);
        var writer = &file_writer.interface;

        try writer.writeAll("{");
        try writer.print("\"Id\":\"{s}\",", .{img.id});
        try writer.print("\"Created\":{d},", .{img.created});
        try writer.print("\"Size\":{d},", .{img.size});
        try writer.print("\"Architecture\":\"{s}\",", .{img.architecture});
        try writer.print("\"Os\":\"{s}\",", .{img.os});

        try writer.writeAll("\"RepoTags\":[");
        for (img.repo_tags, 0..) |t, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("\"{s}\"", .{t});
        }
        try writer.writeAll("],");

        try writer.writeAll("\"RepoDigests\":[");
        for (img.repo_digests, 0..) |d, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("\"{s}\"", .{d});
        }
        try writer.writeAll("],");

        try writer.writeAll("\"RootFS\":{\"Layers\":[");
        for (img.rootfs.layers, 0..) |l, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("\"{s}\"", .{l});
        }
        try writer.writeAll("]}");
        try writer.writeAll("}");
    }

    pub fn tagImage(self: *ImageService, name: []const u8, repo: []const u8, tag_val: []const u8) !void {
        self.lock.lockSharedUncancelable(self.config.io);
        const img = try self.getImage(name);
        self.lock.unlockShared(self.config.io);

        self.lock.lockUncancelable(self.config.io);
        defer self.lock.unlock(self.config.io);

        const new_tag = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ repo, tag_val });
        errdefer self.allocator.free(new_tag);

        if (self.by_tag.contains(new_tag)) {
            self.allocator.free(new_tag);
            return;
        }

        var new_tags = try self.allocator.alloc([]const u8, img.repo_tags.len + 1);
        @memcpy(new_tags[0..img.repo_tags.len], img.repo_tags);
        new_tags[img.repo_tags.len] = new_tag;

        const old_tags = img.repo_tags;
        img.repo_tags = new_tags;
        if (old_tags.len > 0) self.allocator.free(old_tags);

        try self.by_tag.put(new_tag, img);

        try self.saveImageToDisk(img);
    }

    pub fn removeImage(self: *ImageService, name: []const u8, force: bool, noprune: bool) ![]RemoveResponseItem {
        _ = force;
        _ = noprune;
        self.lock.lockUncancelable(self.config.io);
        defer self.lock.unlock(self.config.io);

        var tag_buf: [256]u8 = undefined;
        const target_tag = if (std.mem.indexOfScalar(u8, name, ':') != null)
            name
        else
            std.fmt.bufPrint(&tag_buf, "{s}:latest", .{name}) catch name;

        var found_img: ?*Image = self.by_tag.get(target_tag);
        const tag_to_remove: ?[]const u8 = if (found_img != null) target_tag else null;

        var is_id_match = false;
        if (found_img == null) {
            if (self.by_id.get(name)) |img| {
                found_img = img;
                is_id_match = true;
            } else {
                var prefix_match: ?*Image = null;
                var it2 = self.by_id.iterator();
                while (it2.next()) |entry| {
                    if (std.mem.startsWith(u8, entry.key_ptr.*, name)) {
                        if (prefix_match != null) return CrateError.ImageNotFound;
                        prefix_match = entry.value_ptr.*;
                    }
                }
                if (prefix_match) |img| {
                    found_img = img;
                    is_id_match = true;
                }
            }
        }

        const img = found_img orelse return CrateError.ImageNotFound;

        var response = std.ArrayList(RemoveResponseItem).empty;
        errdefer response.deinit(self.allocator);

        if (is_id_match or img.repo_tags.len <= 1) {
            for (img.repo_tags) |t| {
                _ = self.by_tag.remove(t);
                try response.append(self.allocator, .{ .untagged = try self.allocator.dupe(u8, t) });
            }

            var hash = img.id;
            if (std.mem.startsWith(u8, hash, "sha256:")) hash = hash[7..];
            var path_buf: [512]u8 = undefined;
            const img_path = try std.fmt.bufPrint(&path_buf, "{s}/image/overlay2/imagedb/content/sha256/{s}", .{ self.config.data_root, hash });
            std.Io.Dir.deleteFileAbsolute(self.config.io, img_path) catch |err| {
                std.log.warn("failed to delete image file {s}: {}", .{ img_path, err });
            };

            _ = self.by_id.remove(img.id);
            try response.append(self.allocator, .{ .deleted = try self.allocator.dupe(u8, img.id) });

            self.allocator.free(img.id);
            for (img.repo_tags) |t| self.allocator.free(t);
            self.allocator.free(img.repo_tags);
            for (img.repo_digests) |d| self.allocator.free(d);
            self.allocator.free(img.repo_digests);
            self.allocator.destroy(img);
        } else {
            _ = self.by_tag.remove(tag_to_remove.?);

            var new_tags = try self.allocator.alloc([]const u8, img.repo_tags.len - 1);
            var idx: usize = 0;
            for (img.repo_tags) |t| {
                if (std.mem.eql(u8, t, tag_to_remove.?)) {
                    try response.append(self.allocator, .{ .untagged = try self.allocator.dupe(u8, t) });
                    self.allocator.free(t);
                } else {
                    new_tags[idx] = t;
                    idx += 1;
                }
            }
            const old_tags = img.repo_tags;
            img.repo_tags = new_tags;
            self.allocator.free(old_tags);
            try self.saveImageToDisk(img);
        }

        return try response.toOwnedSlice(self.allocator);
    }

    pub fn pullImage(self: *ImageService, from_image: []const u8, tag_val: []const u8) !*Image {
        self.lock.lockUncancelable(self.config.io);
        defer self.lock.unlock(self.config.io);

        var repo = from_image;
        var tag_str = tag_val;
        if (std.mem.indexOfScalar(u8, from_image, ':')) |colon| {
            repo = from_image[0..colon];
            tag_str = from_image[colon + 1 ..];
        }

        var tag_buf: [256]u8 = undefined;
        const target_tag = try std.fmt.bufPrint(&tag_buf, "{s}:{s}", .{ repo, tag_str });

        if (self.by_tag.get(target_tag)) |img| return img;

        var bytes: [32]u8 = undefined;
        try self.config.io.randomSecure(&bytes);
        var hex_buf: [64]u8 = undefined;
        @memcpy(&hex_buf, std.fmt.bytesToHex(bytes, .lower)[0..64]);

        const full_id = try std.fmt.allocPrint(self.allocator, "sha256:{s}", .{hex_buf});
        errdefer self.allocator.free(full_id);

        var repo_tags = try self.allocator.alloc([]const u8, 1);
        errdefer self.allocator.free(repo_tags);

        repo_tags[0] = try self.allocator.dupe(u8, target_tag);
        errdefer self.allocator.free(repo_tags[0]);

        const img = try self.allocator.create(Image);
        errdefer {
            self.allocator.free(full_id);
            self.allocator.free(repo_tags[0]);
            self.allocator.free(repo_tags);
            self.allocator.destroy(img);
        }

        const arch = try self.allocator.dupe(u8, "amd64");
        errdefer self.allocator.free(arch);

        const os_name = try self.allocator.dupe(u8, "linux");
        errdefer self.allocator.free(os_name);

        const now = std.Io.Clock.now(.awake, self.config.io).toNanoseconds();

        img.* = .{
            .id = full_id,
            .repo_tags = repo_tags,
            .repo_digests = &.{},
            .created = @intCast(now),
            .architecture = arch,
            .os = os_name,
            .size = 1000,
            .rootfs = .{ .layers = &.{} },
            .config = .{
                .exposesd_ports = std.StringHashMap(void).init(self.allocator),
            },
        };

        self.saveImageToDisk(img) catch {};
        try self.by_id.put(img.id, img);
        try self.by_tag.put(img.repo_tags[0], img);

        return img;
    }
};

pub const RemoveResponseItem = struct {
    untagged: ?[]const u8 = null,
    deleted: ?[]const u8 = null,

    pub fn jsonStringify(self: RemoveResponseItem, jws: anytype) !void {
        try jws.beginObject();
        if (self.untagged) |u| {
            try jws.objectField("Untagged");
            try jws.write(u);
        }
        if (self.deleted) |d| {
            try jws.objectField("Deleted");
            try jws.write(d);
        }
        try jws.endObject();
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
