const std = @import("std");

pub const PushManifest = struct {
    schema_version: u32 = 2,
    media_type: []const u8 = "application/vnd.docker.distribution.manifest.v2+json",
    config_digest: []const u8,
    config_size: usize,
    layers: []const LayerDescriptor,

    pub const LayerDescriptor = struct {
        media_type: []const u8 = "application/vnd.docker.image.rootfs.diff.tar.gzip",
        size: usize,
        digest: []const u8,
    };
};

pub const ImagePusher = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ImagePusher {
        return .{ .allocator = allocator };
    }

    pub fn formatUploadUrl(self: ImagePusher, registry: []const u8, repository: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "https://{s}/v2/{s}/blobs/uploads/", .{ registry, repository });
    }

    pub fn formatManifestUrl(self: ImagePusher, registry: []const u8, repository: []const u8, tag: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "https://{s}/v2/{s}/manifests/{s}", .{ registry, repository, tag });
    }
};

test "image pusher url formatting" {
    const alloc = std.testing.allocator;
    const pusher = ImagePusher.init(alloc);

    const upload_url = try pusher.formatUploadUrl("registry-1.docker.io", "library/alpine");
    defer alloc.free(upload_url);
    try std.testing.expectEqualStrings("https://registry-1.docker.io/v2/library/alpine/blobs/uploads/", upload_url);

    const manifest_url = try pusher.formatManifestUrl("registry-1.docker.io", "library/alpine", "latest");
    defer alloc.free(manifest_url);
    try std.testing.expectEqualStrings("https://registry-1.docker.io/v2/library/alpine/manifests/latest", manifest_url);
}
