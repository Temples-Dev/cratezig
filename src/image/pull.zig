//! `docker pull`: resolve → manifest → config → layers → image record.
const std = @import("std");
const ImageService = @import("service.zig").ImageService;
const Image = @import("types.zig").Image;
const reference = @import("reference.zig");
const registry = @import("registry.zig");
const manifest = @import("manifest.zig");
const content = @import("content.zig");
const layers = @import("layers.zig");
const unpack = @import("unpack.zig");
const timefmt = @import("../util/timefmt.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Receives Docker-style progress messages ("Pulling fs layer", …).
pub const Progress = struct {
    ctx: *anyopaque,
    emitFn: *const fn (ctx: *anyopaque, id: []const u8, status: []const u8, current: u64, total: u64) void,

    pub fn emit(self: Progress, id: []const u8, status: []const u8, current: u64, total: u64) void {
        self.emitFn(self.ctx, id, status, current, total);
    }

    fn noop(_: *anyopaque, _: []const u8, _: []const u8, _: u64, _: u64) void {}
    pub const none: Progress = .{ .ctx = undefined, .emitFn = noop };
};

pub const Options = struct {
    creds: ?registry.Credentials = null,
    insecure_registries: []const []const u8 = &.{},
    platform: manifest.Platform = .host(),
};

pub const Result = struct {
    image: *Image,
    /// Nothing new was downloaded.
    up_to_date: bool,
    digest: [71]u8,
};

pub fn pull(svc: *ImageService, raw_ref: []const u8, opts: Options, progress: Progress) !Result {
    const gpa = svc.allocator;
    const io = svc.config.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const ref = try reference.parse(a, raw_ref);
    var client = registry.Client.init(gpa, io, ref, opts.creds, plainHttp(ref.registry, opts.insecure_registries));
    defer client.deinit();

    // Resolve an index to the platform manifest.
    var fetched = try client.getManifest(a, ref.manifestRef());
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, fetched.body, .{});
    if (parsed != .object) return error.UnsupportedManifest;
    if (try manifest.kindOf(fetched.content_type, parsed.object) == .index) {
        const desc = try manifest.selectFromIndex(parsed.object, opts.platform);
        fetched = try client.getManifest(a, desc.digest);
        parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, fetched.body, .{});
        if (parsed != .object) return error.UnsupportedManifest;
    }
    const man = try manifest.parseManifest(a, parsed.object);
    const manifest_digest = content.digestOf(fetched.body);

    // Serialize the rest: layer directories are shared between images.
    svc.pull_mutex.lockUncancelable(io);
    defer svc.pull_mutex.unlock(io);

    try client.fetchBlob(&svc.content, man.config, {});
    const config_raw = try svc.content.readAlloc(a, man.config.digest, 16 * 1024 * 1024);
    const cfg = try manifest.parseConfig(a, config_raw);
    if (cfg.diff_ids.len != man.layers.len) return error.InvalidImageConfig;
    const chain = try layers.chainIds(a, cfg.diff_ids);

    var downloaded = false;
    for (man.layers, 0..) |layer, i| {
        const short = content.hex(layer.desc.digest)[0..12];
        if (svc.layers.exists(&chain[i])) {
            progress.emit(short, "Already exists", 0, 0);
            continue;
        }
        downloaded = true;
        progress.emit(short, "Pulling fs layer", 0, 0);
        var tracker: Tracker = .{ .progress = progress, .id = short, .total = layer.desc.size };
        try client.fetchBlob(&svc.content, layer.desc, &tracker);
        progress.emit(short, "Download complete", 0, 0);
        progress.emit(short, "Extracting", 0, layer.desc.size);
        try extract(svc, layer, cfg.diff_ids[i], &chain[i], if (i > 0) &chain[i - 1] else null);
        progress.emit(short, "Pull complete", 0, 0);
    }

    var tag_buf: [512]u8 = undefined;
    var digest_buf: [512]u8 = undefined;
    const img = try Image.create(gpa);
    errdefer img.destroy(gpa);
    const ia = img.allocator();
    img.id = try ia.dupe(u8, man.config.digest);
    img.repo_tags = if (ref.digest == null) try dupeList(ia, &.{try ref.familiarTag(&tag_buf)}) else &.{};
    img.repo_digests = try dupeList(ia, &.{try std.fmt.bufPrint(&digest_buf, "{s}@{s}", .{ ref.familiarName(), &manifest_digest })});
    img.created = @intCast(timefmt.parseRfc3339(cfg.created) orelse 0);
    img.architecture = try ia.dupe(u8, cfg.architecture);
    img.os = try ia.dupe(u8, cfg.os);
    for (man.layers) |l| img.size += @intCast(l.desc.size);
    img.rootfs.layers = try dupeList(ia, cfg.diff_ids);
    img.config = .{
        .cmd = try dupeList(ia, cfg.cmd),
        .entrypoint = try dupeList(ia, cfg.entrypoint),
        .env = try dupeList(ia, cfg.env),
        .working_dir = try ia.dupe(u8, cfg.working_dir),
        .user = try ia.dupe(u8, cfg.user),
        .exposed_ports = try dupeList(ia, cfg.exposed_ports),
    };

    return .{ .image = try svc.addImage(img), .up_to_date = !downloaded, .digest = manifest_digest };
}

/// Decompresses a stored layer blob into a fresh layer dir, checking the
/// uncompressed stream against the config's diff_id before committing.
fn extract(svc: *ImageService, layer: manifest.Layer, diff_id: []const u8, chain: []const u8, parent: ?[]const u8) !void {
    const io = svc.config.io;
    const gpa = svc.allocator;
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.Io.Dir.openFileAbsolute(io, try svc.content.blobPath(layer.desc.digest, &path_buf), .{});
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &file_buf);

    const window = try gpa.alloc(u8, switch (layer.compression) {
        .gzip => std.compress.flate.max_window_len,
        .zstd => std.compress.zstd.default_window_len + std.compress.zstd.block_size_max,
        .none => 0,
    });
    defer gpa.free(window);
    var gz: std.compress.flate.Decompress = undefined;
    var zs: std.compress.zstd.Decompress = undefined;
    const src: *std.Io.Reader = switch (layer.compression) {
        .gzip => blk: {
            gz = .init(&fr.interface, .gzip, window);
            break :blk &gz.reader;
        },
        .zstd => blk: {
            zs = .init(&fr.interface, window, .{});
            break :blk &zs.reader;
        },
        .none => &fr.interface,
    };
    var hash_buf: [64 * 1024]u8 = undefined;
    var hashed = src.hashed(Sha256.init(.{}), &hash_buf);

    var diff_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const diff = try svc.layers.prepare(&diff_buf, chain, parent);
    errdefer svc.layers.abort(chain);
    const stats = try unpack.apply(gpa, diff, &hashed.reader);
    _ = try hashed.reader.discardRemaining(); // trailing tar padding counts toward diff_id
    if (stats.skipped_privileged > 0) {
        std.log.warn("layer {s}: skipped {d} ownership/device/xattr ops (not root)", .{ content.hex(chain)[0..12], stats.skipped_privileged });
    }
    var sum: [32]u8 = undefined;
    hashed.hasher.final(&sum);
    if (!std.mem.eql(u8, &content.format(sum), diff_id)) return error.DiffIdMismatch;
    try svc.layers.commit(chain);
    // The unpacked layer is the source of truth now; drop the compressed copy.
    std.Io.Dir.deleteFileAbsolute(io, try svc.content.blobPath(layer.desc.digest, &path_buf)) catch {};
}

const Tracker = struct {
    progress: Progress,
    id: []const u8,
    total: u64,
    last: u64 = 0,

    /// Throttled to one message per MiB.
    pub fn update(self: *Tracker, current: u64) void {
        if (current - self.last < 1 << 20 and current != self.total) return;
        self.last = current;
        self.progress.emit(self.id, "Downloading", current, self.total);
    }
};

fn plainHttp(registry_host: []const u8, insecure: []const []const u8) bool {
    if (std.mem.startsWith(u8, registry_host, "localhost") or std.mem.startsWith(u8, registry_host, "127.0.0.1")) return true;
    for (insecure) |r| if (std.mem.eql(u8, r, registry_host)) return true;
    return false;
}

fn dupeList(a: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, src.len);
    for (src, 0..) |s, i| out[i] = try a.dupe(u8, s);
    return out;
}
