const std = @import("std");

pub const Image = struct {
    /// Owns every slice below; freed with the image.
    arena: std.heap.ArenaAllocator,

    id: []const u8,
    repo_tags: []const []const u8 = &.{},
    repo_digests: []const []const u8 = &.{},
    created: i64 = 0,
    architecture: []const u8 = "amd64",
    os: []const u8 = "linux",
    size: i64 = 0,
    rootfs: RootFS = .{},
    config: ImageConfig = .{},

    pub fn create(gpa: std.mem.Allocator) !*Image {
        const img = try gpa.create(Image);
        img.* = .{ .arena = .init(gpa), .id = "" };
        return img;
    }

    pub fn allocator(self: *Image) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn destroy(self: *Image, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

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
        try jws.objectField("RootFS");
        try jws.beginObject();
        try jws.objectField("Type");
        try jws.write("layers");
        try jws.objectField("Layers");
        try jws.write(self.rootfs.layers);
        try jws.endObject();
        try jws.objectField("Config");
        try jws.write(self.config);
        try jws.endObject();
    }
};

pub const RootFS = struct {
    layers: []const []const u8 = &.{},
};

pub const ImageConfig = struct {
    cmd: []const []const u8 = &.{},
    entrypoint: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    working_dir: []const u8 = "",
    user: []const u8 = "",
    exposed_ports: []const []const u8 = &.{},

    pub fn jsonStringify(self: ImageConfig, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Cmd");
        try jws.write(self.cmd);
        try jws.objectField("Entrypoint");
        try jws.write(self.entrypoint);
        try jws.objectField("Env");
        try jws.write(self.env);
        try jws.objectField("WorkingDir");
        try jws.write(self.working_dir);
        try jws.objectField("User");
        try jws.write(self.user);
        try jws.objectField("ExposedPorts");
        try jws.beginObject();
        for (self.exposed_ports) |p| {
            try jws.objectField(p);
            try jws.beginObject();
            try jws.endObject();
        }
        try jws.endObject();
        try jws.endObject();
    }
};
