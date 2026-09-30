//! OCI / Docker v2 manifest, index and image-config parsing.
const std = @import("std");
const builtin = @import("builtin");
const reference = @import("reference.zig");
const ju = @import("../util/jsonutil.zig");

pub const media = struct {
    pub const oci_index = "application/vnd.oci.image.index.v1+json";
    pub const oci_manifest = "application/vnd.oci.image.manifest.v1+json";
    pub const docker_list = "application/vnd.docker.distribution.manifest.list.v2+json";
    pub const docker_manifest = "application/vnd.docker.distribution.manifest.v2+json";
    /// Accept header for manifest requests, most preferred first.
    pub const accept = oci_index ++ ", " ++ docker_list ++ ", " ++ oci_manifest ++ ", " ++ docker_manifest;
};

pub const Compression = enum { none, gzip, zstd };

pub const Descriptor = struct {
    digest: []const u8,
    size: u64,
    media_type: []const u8 = "",
};

pub const Layer = struct {
    desc: Descriptor,
    compression: Compression,
};

pub const Manifest = struct {
    config: Descriptor,
    layers: []const Layer,
};

pub const Kind = enum { index, manifest };

pub fn kindOf(content_type: []const u8, body: std.json.ObjectMap) !Kind {
    const mt = ju.str(body.get("mediaType")) orelse content_type;
    if (std.mem.startsWith(u8, mt, media.oci_index) or std.mem.startsWith(u8, mt, media.docker_list)) return .index;
    if (std.mem.startsWith(u8, mt, media.oci_manifest) or std.mem.startsWith(u8, mt, media.docker_manifest)) return .manifest;
    // OCI allows omitting mediaType; infer from shape.
    if (body.get("manifests") != null) return .index;
    if (body.get("layers") != null) return .manifest;
    return error.UnsupportedManifest;
}

pub const Platform = struct {
    os: []const u8 = "linux",
    architecture: []const u8,
    variant: []const u8 = "",

    pub fn host() Platform {
        return switch (builtin.cpu.arch) {
            .x86_64 => .{ .architecture = "amd64" },
            .aarch64 => .{ .architecture = "arm64", .variant = "v8" },
            .arm => .{ .architecture = "arm", .variant = "v7" },
            .riscv64 => .{ .architecture = "riscv64" },
            else => .{ .architecture = @tagName(builtin.cpu.arch) },
        };
    }
};

/// Picks the manifest for `want` from an index. A missing variant on either
/// side matches (arm64 images often omit "v8").
pub fn selectFromIndex(body: std.json.ObjectMap, want: Platform) !Descriptor {
    const list = switch (body.get("manifests") orelse return error.UnsupportedManifest) {
        .array => |a| a.items,
        else => return error.UnsupportedManifest,
    };
    for (list) |item| {
        const m = ju.object(item) orelse continue;
        const p = ju.object(m.get("platform")) orelse continue;
        if (!std.mem.eql(u8, ju.str(p.get("os")) orelse "", want.os)) continue;
        if (!std.mem.eql(u8, ju.str(p.get("architecture")) orelse "", want.architecture)) continue;
        const variant = ju.str(p.get("variant")) orelse "";
        if (variant.len > 0 and want.variant.len > 0 and !std.mem.eql(u8, variant, want.variant)) continue;
        return try descriptor(m);
    }
    return error.NoMatchingPlatform;
}

pub fn parseManifest(a: std.mem.Allocator, body: std.json.ObjectMap) !Manifest {
    const config = try descriptor(ju.object(body.get("config")) orelse return error.UnsupportedManifest);
    const raw_layers = switch (body.get("layers") orelse return error.UnsupportedManifest) {
        .array => |x| x.items,
        else => return error.UnsupportedManifest,
    };
    const layers = try a.alloc(Layer, raw_layers.len);
    for (raw_layers, 0..) |item, i| {
        const d = try descriptor(ju.object(item) orelse return error.UnsupportedManifest);
        layers[i] = .{ .desc = d, .compression = try compressionOf(d.media_type) };
    }
    return .{ .config = config, .layers = layers };
}

fn descriptor(m: std.json.ObjectMap) !Descriptor {
    const digest = ju.str(m.get("digest")) orelse return error.UnsupportedManifest;
    if (!reference.validDigest(digest)) return error.UnsupportedManifest;
    const size = ju.int(m.get("size")) orelse return error.UnsupportedManifest;
    if (size < 0) return error.UnsupportedManifest;
    return .{ .digest = digest, .size = @intCast(size), .media_type = ju.str(m.get("mediaType")) orelse "" };
}

fn compressionOf(mt: []const u8) !Compression {
    if (std.mem.endsWith(u8, mt, "+gzip") or std.mem.endsWith(u8, mt, ".tar.gzip")) return .gzip;
    if (std.mem.endsWith(u8, mt, "+zstd")) return .zstd;
    if (std.mem.endsWith(u8, mt, ".tar") or std.mem.endsWith(u8, mt, "layer.v1.tar")) return .none;
    // Foreign / nondistributable layers (Windows base images) are not supported.
    return error.UnsupportedLayer;
}

/// The parts of an image config (`application/vnd.oci.image.config.v1+json`)
/// cratezig uses. Slices are allocated with the given allocator.
pub const Config = struct {
    architecture: []const u8 = "",
    os: []const u8 = "",
    created: []const u8 = "",
    cmd: []const []const u8 = &.{},
    entrypoint: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    working_dir: []const u8 = "",
    user: []const u8 = "",
    stop_signal: []const u8 = "",
    exposed_ports: []const []const u8 = &.{},
    volumes: []const []const u8 = &.{},
    diff_ids: []const []const u8 = &.{},
};

pub fn parseConfig(a: std.mem.Allocator, raw: []const u8) !Config {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{});
    const root = ju.object(parsed) orelse return error.InvalidImageConfig;
    var out: Config = .{
        .architecture = ju.str(root.get("architecture")) orelse "",
        .os = ju.str(root.get("os")) orelse "",
        .created = ju.str(root.get("created")) orelse "",
    };
    if (ju.object(root.get("config"))) |c| {
        out.cmd = try ju.strings(a, c.get("Cmd"));
        out.entrypoint = try ju.strings(a, c.get("Entrypoint"));
        out.env = try ju.strings(a, c.get("Env"));
        out.working_dir = ju.str(c.get("WorkingDir")) orelse "";
        out.user = ju.str(c.get("User")) orelse "";
        out.stop_signal = ju.str(c.get("StopSignal")) orelse "";
        out.exposed_ports = try ju.keys(a, c.get("ExposedPorts"));
        out.volumes = try ju.keys(a, c.get("Volumes"));
    }
    const rootfs = ju.object(root.get("rootfs")) orelse return error.InvalidImageConfig;
    out.diff_ids = try ju.strings(a, rootfs.get("diff_ids"));
    for (out.diff_ids) |d| if (!reference.validDigest(d)) return error.InvalidImageConfig;
    return out;
}

test "index selection and manifest parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d1 = "sha256:" ++ "1" ** 64;
    const d2 = "sha256:" ++ "2" ** 64;

    const index = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"mediaType\":\"" ++ media.oci_index ++
        "\",\"manifests\":[{\"digest\":\"" ++ d1 ++ "\",\"size\":1,\"platform\":{\"os\":\"linux\",\"architecture\":\"arm64\"}}," ++
        "{\"digest\":\"" ++ d2 ++ "\",\"size\":2,\"platform\":{\"os\":\"linux\",\"architecture\":\"amd64\"}}]}", .{});
    try std.testing.expectEqual(Kind.index, try kindOf("", index.object));
    const picked = try selectFromIndex(index.object, .{ .architecture = "arm64", .variant = "v8" });
    try std.testing.expectEqualStrings(d1, picked.digest);
    try std.testing.expectError(error.NoMatchingPlatform, selectFromIndex(index.object, .{ .architecture = "s390x" }));

    const man = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"config\":{\"digest\":\"" ++ d1 ++
        "\",\"size\":3},\"layers\":[{\"digest\":\"" ++ d2 ++ "\",\"size\":4,\"mediaType\":\"application/vnd.oci.image.layer.v1.tar+zstd\"}]}", .{});
    try std.testing.expectEqual(Kind.manifest, try kindOf(media.docker_manifest, man.object));
    const m = try parseManifest(a, man.object);
    try std.testing.expectEqual(Compression.zstd, m.layers[0].compression);

    const cfg = try parseConfig(a, "{\"architecture\":\"amd64\",\"config\":{\"Cmd\":[\"sh\"],\"ExposedPorts\":{\"80/tcp\":{}}},\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[\"" ++ d2 ++ "\"]}}");
    try std.testing.expectEqualStrings("sh", cfg.cmd[0]);
    try std.testing.expectEqualStrings("80/tcp", cfg.exposed_ports[0]);
    try std.testing.expectEqualStrings(d2, cfg.diff_ids[0]);
}
