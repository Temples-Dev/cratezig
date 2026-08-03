const std = @import("std");

pub const Image = struct {
    id: []const u8,
    repo_tags: [][]const u8,
    repo_digests: [][]const u8,
    created: i64,
    architecture: []const u8 = "amd64",
    os: []const u8 = "linux",
    size: i64,
    rootfs: RootFS,
    config: ImageConfig,

    pub fn jsonStringify(self: Image, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Id");
        try jws.write(self.id);
        try jws.objectField("RepoTags");
        try jws.write(self.repo_tags);
        try jws.objectField("RepoDigests");
        try jws.write(self.repo_digests);
        try jws.objectField("Created");
        try jws.write(self.created);
        try jws.objectField("Architecture");
        try jws.write(self.architecture);
        try jws.objectField("Os");
        try jws.write(self.os);
        try jws.objectField("Size");
        try jws.write(self.size);
        try jws.endObject();
    }
};

pub const RootFS = struct {
    layers: [][]const u8,
};

pub const ImageConfig = struct {
    cmd: [][]const u8 = &.{},
    entrypoint: [][]const u8 = &.{},
    env: [][]const u8 = &.{},
    working_dir: []const u8 = "/",
    user: []const u8 = "",
    exposesd_ports: std.StringHashMap(void),
};
