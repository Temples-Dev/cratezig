const std = @import("std");
const DaemonConfig = @import("../config/config.zig").DaemonConfig;
pub const Image = @import("types.zig").Image;
const CrateError = @import("../errdefs/errors.zig").Error;
const fsutil = @import("../util/fsutil.zig");
const ju = @import("../util/jsonutil.zig");
const overlay = @import("overlay.zig");
const content = @import("content.zig");
const layers = @import("layers.zig");

pub const LoadError = error{ InvalidJson, MissingId };

pub const ImageService = struct {
    allocator: std.mem.Allocator,
    config: DaemonConfig,
    /// Keyed by full id ("sha256:<hex>"). Owns the images.
    by_id: std.StringHashMap(*Image),
    /// Keyed by "repo:tag"; keys are owned by the image's arena.
    by_tag: std.StringHashMap(*Image),
    lock: std.Io.RwLock = .init,
    content: content.Store,
    layers: layers.Store,
    /// Serializes pulls so two pulls never unpack the same layer at once.
    pull_mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, config: DaemonConfig) !ImageService {
        var svc = ImageService{
            .allocator = allocator,
            .config = config,
            .by_id = .init(allocator),
            .by_tag = .init(allocator),
            .content = try content.Store.init(config.io, allocator, config.data_root),
            .layers = .{ .io = config.io, .data_root = config.data_root },
        };
        errdefer svc.deinit();
        try svc.loadFromDisk();
        return svc;
    }

    pub fn deinit(self: *ImageService) void {
        var it = self.by_id.valueIterator();
        while (it.next()) |img| img.*.release();
        self.by_id.deinit();
        self.by_tag.deinit();
        self.content.deinit(self.allocator);
    }

    /// Resolves `ref`. The result is retained; the caller must `release()` it.
    pub fn getImage(self: *ImageService, ref: []const u8) !*Image {
        self.lock.lockSharedUncancelable(self.config.io);
        defer self.lock.unlockShared(self.config.io);
        return (try self.getImageLocked(ref)).retain();
    }

    /// Resolves an id, `sha256:`-less id, unique id prefix, or `repo[:tag]`.
    /// Caller holds `lock`.
    fn getImageLocked(self: *ImageService, ref: []const u8) !*Image {
        if (self.by_id.get(ref)) |img| return img;

        var tag_buf: [512]u8 = undefined;
        if (self.by_tag.get(try withDefaultTag(ref, &tag_buf))) |img| return img;

        const hex = if (std.mem.startsWith(u8, ref, "sha256:")) ref[7..] else ref;
        if (hex.len == 0) return CrateError.ImageNotFound;
        var match: ?*Image = null;
        var it = self.by_id.iterator();
        while (it.next()) |e| {
            const id_hex = if (std.mem.startsWith(u8, e.key_ptr.*, "sha256:")) e.key_ptr.*[7..] else e.key_ptr.*;
            if (std.mem.startsWith(u8, id_hex, hex)) {
                if (match != null) return CrateError.ImageNotFound; // ambiguous
                match = e.value_ptr.*;
            }
        }
        return match orelse CrateError.ImageNotFound;
    }

    /// Creates the overlay2 directories for a container's writable layer and
    /// points its `lower` at the image's top layer.
    pub fn createWritableLayer(self: *ImageService, id: *const [64]u8, image: *Image) !void {
        for ([_][]const u8{ "diff", "work", "merged" }) |sub| {
            var buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}/overlay2/{s}/{s}", .{ self.config.data_root, id, sub });
            try std.Io.Dir.createDirPath(.cwd(), self.config.io, path);
        }
        if (image.rootfs.layers.len == 0) return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const chain = try layers.chainIds(arena.allocator(), image.rootfs.layers);
        const top = &chain[chain.len - 1];
        if (!self.layers.exists(top)) return error.ImageLayersMissing;
        var lower_buf: [4096]u8 = undefined;
        var path_buf: [512]u8 = undefined;
        const lower_path = try std.fmt.bufPrint(&path_buf, "{s}/overlay2/{s}/lower", .{ self.config.data_root, id });
        try fsutil.writeFileAtomic(self.config.io, lower_path, try self.layers.lowerFor(&lower_buf, top));
    }

    /// Registers a freshly pulled image, taking ownership of `img`. Tags move
    /// from any image that held them; an image with the same id is merged.
    pub fn addImage(self: *ImageService, img: *Image) !*Image {
        self.lock.lockUncancelable(self.config.io);
        defer self.lock.unlock(self.config.io);

        const target = self.by_id.get(img.id) orelse blk: {
            const owned_tags = img.repo_tags;
            img.repo_tags = &.{};
            try self.by_id.put(img.id, img);
            for (owned_tags) |t| try self.moveTag(img, t);
            break :blk img;
        };
        if (target != img) {
            defer img.destroy(self.allocator);
            for (img.repo_tags) |t| try self.moveTag(target, t);
            for (img.repo_digests) |d| try self.addDigest(target, d);
        }
        try self.saveImageToDisk(target);
        return target;
    }

    /// Points `tag` at `img`, removing it from whichever image had it.
    /// Caller holds the write lock.
    fn moveTag(self: *ImageService, img: *Image, tag: []const u8) !void {
        if (self.by_tag.get(tag)) |prev| {
            if (prev == img) return;
            try self.untag(prev, tag);
        }
        const a = img.allocator();
        const owned = try a.dupe(u8, tag);
        const tags = try a.alloc([]const u8, img.repo_tags.len + 1);
        @memcpy(tags[0..img.repo_tags.len], img.repo_tags);
        tags[img.repo_tags.len] = owned;
        img.repo_tags = tags;
        try self.by_tag.put(owned, img);
    }

    fn addDigest(self: *ImageService, img: *Image, digest: []const u8) !void {
        _ = self;
        for (img.repo_digests) |d| if (std.mem.eql(u8, d, digest)) return;
        const a = img.allocator();
        const digests = try a.alloc([]const u8, img.repo_digests.len + 1);
        @memcpy(digests[0..img.repo_digests.len], img.repo_digests);
        digests[img.repo_digests.len] = try a.dupe(u8, digest);
        img.repo_digests = digests;
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

        const result = try allocator.alloc(*Image, self.by_id.count());
        var it = self.by_id.valueIterator();
        var i: usize = 0;
        while (it.next()) |img| : (i += 1) result[i] = img.*.retain();
        return result;
    }

    pub fn releaseList(allocator: std.mem.Allocator, items: []*Image) void {
        for (items) |img| img.release();
        allocator.free(items);
    }

    fn imagePath(self: *ImageService, id: []const u8, buf: []u8) ![]u8 {
        const hex = if (std.mem.startsWith(u8, id, "sha256:")) id[7..] else id;
        return std.fmt.bufPrint(buf, "{s}/image/overlay2/imagedb/content/sha256/{s}", .{ self.config.data_root, hex });
    }

    fn index(self: *ImageService, img: *Image) !void {
        try self.by_id.put(img.id, img);
        for (img.repo_tags) |t| try self.by_tag.put(t, img);
    }

    fn loadFromDisk(self: *ImageService) !void {
        var path_buf: [512]u8 = undefined;
        const images_dir = try std.fmt.bufPrint(&path_buf, "{s}/image/overlay2/imagedb/content/sha256", .{self.config.data_root});

        var dir = std.Io.Dir.openDir(.cwd(), self.config.io, images_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.close(self.config.io);

        var it = dir.iterate();
        while (try it.next(self.config.io)) |entry| {
            if (entry.kind != .file or std.mem.endsWith(u8, entry.name, ".tmp")) continue;
            var img_path_buf: [512]u8 = undefined;
            const img_path = try std.fmt.bufPrint(&img_path_buf, "{s}/{s}", .{ images_dir, entry.name });

            const img = self.loadImageFromFile(img_path) catch |err| {
                std.log.warn("failed to load image {s}: {}", .{ entry.name, err });
                continue;
            };
            self.index(img) catch |err| {
                img.destroy(self.allocator);
                return err;
            };
        }
    }

    fn loadImageFromFile(self: *ImageService, path: []const u8) !*Image {
        const raw = try std.Io.Dir.cwd().readFileAlloc(self.config.io, path, self.allocator, .limited(10 * 1024 * 1024));
        defer self.allocator.free(raw);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{});
        defer parsed.deinit();
        const root = ju.object(parsed.value) orelse return LoadError.InvalidJson;

        const img = try Image.create(self.allocator);
        errdefer img.destroy(self.allocator);
        const a = img.allocator();

        img.id = try a.dupe(u8, ju.str(root.get("Id")) orelse return LoadError.MissingId);
        img.created = ju.int(root.get("Created")) orelse 0;
        img.size = ju.int(root.get("Size")) orelse 0;
        img.architecture = try a.dupe(u8, ju.str(root.get("Architecture")) orelse "amd64");
        img.os = try a.dupe(u8, ju.str(root.get("Os")) orelse "linux");
        img.repo_tags = try ju.strings(a, root.get("RepoTags"));
        img.repo_digests = try ju.strings(a, root.get("RepoDigests"));
        if (ju.object(root.get("RootFS"))) |rfs| img.rootfs.layers = try ju.strings(a, rfs.get("Layers"));
        if (ju.object(root.get("Config"))) |cfg| {
            img.config = .{
                .cmd = try ju.strings(a, cfg.get("Cmd")),
                .entrypoint = try ju.strings(a, cfg.get("Entrypoint")),
                .env = try ju.strings(a, cfg.get("Env")),
                .working_dir = try a.dupe(u8, ju.str(cfg.get("WorkingDir")) orelse ""),
                .user = try a.dupe(u8, ju.str(cfg.get("User")) orelse ""),
                .exposed_ports = try ju.keys(a, cfg.get("ExposedPorts")),
            };
        }
        return img;
    }

    fn saveImageToDisk(self: *ImageService, img: *const Image) !void {
        var path_buf: [512]u8 = undefined;
        try fsutil.writeJsonAtomic(self.config.io, self.allocator, try self.imagePath(img.id, &path_buf), img.*);
    }

    pub fn tagImage(self: *ImageService, name: []const u8, repo: []const u8, tag_val: []const u8) !void {
        self.lock.lockUncancelable(self.config.io);
        defer self.lock.unlock(self.config.io);

        const img = try self.getImageLocked(name);
        var tag_buf: [512]u8 = undefined;
        try self.moveTag(img, try std.fmt.bufPrint(&tag_buf, "{s}:{s}", .{ repo, tag_val }));
        try self.saveImageToDisk(img);
    }

    /// Drops `tag` from `img`. Caller holds the write lock.
    fn untag(self: *ImageService, img: *Image, tag: []const u8) !void {
        _ = self.by_tag.remove(tag);
        const tags = try img.allocator().alloc([]const u8, img.repo_tags.len);
        var n: usize = 0;
        for (img.repo_tags) |t| {
            if (!std.mem.eql(u8, t, tag)) {
                tags[n] = t;
                n += 1;
            }
        }
        img.repo_tags = tags[0..n];
        try self.saveImageToDisk(img);
    }

    /// Untags `name`, deleting the image once no tags remain (or when `name`
    /// is an id). Response strings are allocated with `allocator`.
    /// Untags `name`, deleting the image once no tags remain (or when `name`
    /// is an id). Images whose id is in `in_use` (used by containers) are
    /// only untagged, and only with `force`. Unreferenced layers are
    /// garbage-collected. Response strings are allocated with `allocator`.
    pub fn removeImage(self: *ImageService, allocator: std.mem.Allocator, name: []const u8, force: bool, in_use: []const []const u8) ![]RemoveResponseItem {
        // Before `lock`, matching pull's order: no layer GC while a pull runs.
        self.pull_mutex.lockUncancelable(self.config.io);
        defer self.pull_mutex.unlock(self.config.io);
        self.lock.lockUncancelable(self.config.io);
        defer self.lock.unlock(self.config.io);

        var response = std.ArrayList(RemoveResponseItem).empty;
        errdefer response.deinit(allocator);

        var tag_buf: [512]u8 = undefined;
        const tag = try withDefaultTag(name, &tag_buf);
        const by_tag = self.by_tag.get(tag);
        const img = by_tag orelse try self.getImageLocked(name);
        const used = for (in_use) |id| {
            if (std.mem.eql(u8, id, img.id)) break true;
        } else false;

        if (by_tag != null and (img.repo_tags.len > 1 or used)) {
            if (used and !force) return CrateError.ImageInUse;
            try response.append(allocator, .{ .untagged = try allocator.dupe(u8, tag) });
            try self.untag(img, tag);
            return response.toOwnedSlice(allocator);
        }
        if (used) return CrateError.ImageInUse;

        for (img.repo_tags) |t| {
            _ = self.by_tag.remove(t);
            try response.append(allocator, .{ .untagged = try allocator.dupe(u8, t) });
        }
        try response.append(allocator, .{ .deleted = try allocator.dupe(u8, img.id) });

        var path_buf: [512]u8 = undefined;
        const img_path = try self.imagePath(img.id, &path_buf);
        std.Io.Dir.deleteFileAbsolute(self.config.io, img_path) catch |err| {
            std.log.warn("failed to delete image file {s}: {}", .{ img_path, err });
        };
        if (self.content.blobPath(img.id, &path_buf)) |blob| {
            std.Io.Dir.deleteFileAbsolute(self.config.io, blob) catch {};
        } else |_| {}
        _ = self.by_id.remove(img.id);
        defer img.release();
        self.collectLayers(img) catch |err| std.log.warn("layer GC failed: {}", .{err});

        return response.toOwnedSlice(allocator);
    }

    /// Deletes `gone`'s layers that no remaining image shares. Caller holds
    /// both locks.
    fn collectLayers(self: *ImageService, gone: *Image) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var keep = std.StringHashMap(void).init(a);
        var it = self.by_id.valueIterator();
        while (it.next()) |other| {
            for (try layers.chainIds(a, other.*.rootfs.layers)) |*c| try keep.put(c, {});
        }
        for (try layers.chainIds(a, gone.rootfs.layers)) |*c| {
            if (!keep.contains(c)) self.layers.abort(c);
        }
    }
};

/// Appends ":latest" when `ref` has no tag. A ':' before the last '/' is a
/// registry port ("localhost:5000/app"), not a tag.
fn withDefaultTag(ref: []const u8, buf: []u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, ref, '@') != null) return ref;
    const last_slash = std.mem.lastIndexOfScalar(u8, ref, '/') orelse 0;
    if (std.mem.lastIndexOfScalar(u8, ref, ':')) |colon| if (colon > last_slash) return ref;
    return std.fmt.bufPrint(buf, "{s}:latest", .{ref});
}

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

test "withDefaultTag handles registry ports and digests" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("alpine:latest", try withDefaultTag("alpine", &buf));
    try std.testing.expectEqualStrings("alpine:3.20", try withDefaultTag("alpine:3.20", &buf));
    try std.testing.expectEqualStrings("localhost:5000/app:latest", try withDefaultTag("localhost:5000/app", &buf));
    try std.testing.expectEqualStrings("app@sha256:ab", try withDefaultTag("app@sha256:ab", &buf));
}

test "image metadata round-trips through disk" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.Io.Dir.createDirPath(.cwd(), io, try std.fmt.bufPrint(&dir_buf, "{s}/image/overlay2/imagedb/content/sha256", .{root}));

    var cfg = DaemonConfig.init(io);
    cfg.data_root = root;
    {
        var svc = try ImageService.init(gpa, cfg);
        defer svc.deinit();
        const img = try Image.create(gpa);
        img.id = "sha256:abcdef0123";
        img.repo_tags = &.{"app:1"};
        img.config.cmd = &.{ "echo", "a \"quoted\" arg" };
        try svc.saveImageToDisk(img);
        img.destroy(gpa);
    }

    var svc = try ImageService.init(gpa, cfg);
    defer svc.deinit();
    const img = try svc.getImage("app:1");
    defer img.release();
    try std.testing.expectEqualStrings("a \"quoted\" arg", img.config.cmd[1]);
    const same = try svc.getImage("abcdef");
    defer same.release();
    try std.testing.expect(same == img);

    try svc.tagImage("app:1", "app", "2");
    const removed = try svc.removeImage(gpa, "app:1", false, &.{});
    defer {
        for (removed) |r| if (r.untagged) |u| gpa.free(u);
        gpa.free(removed);
    }
    const app2 = try svc.getImage("app:2");
    defer app2.release();
    try std.testing.expect(app2 == img);
    try std.testing.expectError(CrateError.ImageNotFound, svc.getImage("app:1"));
}
