const std = @import("std");
const Dockerfile = @import("dockerfile.zig").Dockerfile;
const InstructionKind = @import("dockerfile.zig").InstructionKind;
const BuildCache = @import("cache.zig").BuildCache;
const BuildContext = @import("context.zig").BuildContext;
const ImageService = @import("../image/service.zig").ImageService;
const Image = @import("../image/service.zig").Image;
const DaemonConfig = @import("../config/config.zig").DaemonConfig;

pub const Builder = struct {
    allocator: std.mem.Allocator,
    config: DaemonConfig,
    image_service: *ImageService,
    cache: BuildCache,

    pub fn init(allocator: std.mem.Allocator, config: DaemonConfig, image_service: *ImageService) Builder {
        return .{
            .allocator = allocator,
            .config = config,
            .image_service = image_service,
            .cache = BuildCache.init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.cache.deinit();
    }

    pub fn build(
        self: *Builder,
        dockerfile_content: []const u8,
        context_dir: []const u8,
        tag: []const u8,
    ) !*Image {
        var df = try Dockerfile.parse(self.allocator, dockerfile_content);
        defer df.deinit();

        var bctx = try BuildContext.init(self.allocator, self.config.io, context_dir);
        defer bctx.deinit();

        var current_parent: []const u8 = "scratch";
        var env_map = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var it = env_map.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                self.allocator.free(e.value_ptr.*);
            }
            env_map.deinit();
        }

        var work_dir = try self.allocator.dupe(u8, "/");
        defer self.allocator.free(work_dir);

        var final_cmd: ?[]const u8 = null;
        defer if (final_cmd) |c| self.allocator.free(c);

        for (df.instructions) |inst| {
            const cache_key = try BuildCache.computeKey(self.allocator, current_parent, inst.raw, bctx.checksum);
            defer self.allocator.free(cache_key);

            if (self.cache.get(self.config.io, cache_key)) |cached_layer| {
                current_parent = cached_layer;
                continue;
            }

            switch (inst.kind) {
                .from => {
                    if (inst.args.len > 0) {
                        const img = self.image_service.pullImage(inst.args[0], "latest") catch
                            try self.image_service.getImage(inst.args[0]);
                        current_parent = img.id;
                    }
                },
                .env => {
                    if (inst.args.len >= 2) {
                        const k = try self.allocator.dupe(u8, inst.args[0]);
                        const v = try self.allocator.dupe(u8, inst.args[1]);
                        if (try env_map.fetchPut(k, v)) |old| {
                            self.allocator.free(old.key);
                            self.allocator.free(old.value);
                        }
                    }
                },
                .workdir => {
                    if (inst.args.len > 0) {
                        self.allocator.free(work_dir);
                        work_dir = try self.allocator.dupe(u8, inst.args[0]);
                    }
                },
                .cmd => {
                    if (inst.args.len > 0) {
                        if (final_cmd) |c| self.allocator.free(c);
                        final_cmd = try self.allocator.dupe(u8, inst.args[0]);
                    }
                },
                .run, .copy, .add, .expose, .entrypoint, .arg => {},
            }

            var layer_bytes: [32]u8 = undefined;
            try self.config.io.randomSecure(&layer_bytes);
            var hex_buf: [64]u8 = undefined;
            @memcpy(&hex_buf, std.fmt.bytesToHex(layer_bytes, .lower)[0..64]);

            const step_layer = try std.fmt.allocPrint(self.allocator, "sha256:{s}", .{hex_buf});
            try self.cache.put(self.config.io, cache_key, step_layer);
            current_parent = step_layer;
        }

        const img = try self.image_service.pullImage(tag, "latest");
        return img;
    }
};
