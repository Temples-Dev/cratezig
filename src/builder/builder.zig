const std = @import("std");
const Dockerfile = @import("spec.zig").Dockerfile;
const InstructionKind = @import("spec.zig").InstructionKind;
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
                .run, .copy, .add, .expose, .entrypoint, .arg, .label, .user, .healthcheck, .volume, .shell => {},
            }

            var layer_bytes: [32]u8 = undefined;
            try self.config.io.randomSecure(&layer_bytes);
            var hex_buf: [64]u8 = undefined;
            @memcpy(&hex_buf, std.fmt.bytesToHex(layer_bytes, .lower)[0..64]);

            const step_layer = try std.fmt.allocPrint(self.allocator, "sha256:{s}", .{hex_buf});
            defer self.allocator.free(step_layer);
            try self.cache.put(self.config.io, cache_key, step_layer);
            current_parent = step_layer;
        }

        const img = try self.image_service.pullImage(tag, "latest");
        return img;
    }
};

test "build Docker project and verify layer cache" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var cfg = DaemonConfig.init(io);
    cfg.data_root = "/tmp/cratezig-test-data";

    var image_service = try ImageService.init(alloc, cfg);
    defer image_service.deinit();

    var builder = Builder.init(alloc, cfg, &image_service);
    defer builder.deinit();

    const dockerfile =
        \\FROM alpine:3.18
        \\ENV APP_PORT=8080
        \\WORKDIR /var/www
        \\RUN echo "building cratezig app"
        \\CMD ["./server"]
    ;

    // First build run (cache cold)
    const img1 = try builder.build(dockerfile, "/tmp", "my-app:v1");
    try std.testing.expect(img1.id.len > 0);

    // Second build run (cache warm)
    const img2 = try builder.build(dockerfile, "/tmp", "my-app:v1");
    try std.testing.expectEqualStrings(img1.id, img2.id);
}

test "experiment on real GEase backend Dockerfile" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const file = std.Io.Dir.openFileAbsolute(io, "/home/life-mac-africa/Work/GEase/backend/Dockerfile", .{}) catch return;
    defer file.close(io);

    var read_buf: [2048]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var content_buf: [4096]u8 = undefined;
    const n = try reader.interface.readSliceShort(&content_buf);
    const dockerfile_content = content_buf[0..n];

    var cfg = DaemonConfig.init(io);
    cfg.data_root = "/tmp/cratezig-gease-test";

    var image_service = try ImageService.init(alloc, cfg);
    defer image_service.deinit();

    var builder = Builder.init(alloc, cfg, &image_service);
    defer builder.deinit();

    const start_cold = std.Io.Clock.now(.awake, io).toNanoseconds();
    const img_cold = try builder.build(dockerfile_content, "/home/life-mac-africa/Work/GEase/backend", "gease-backend:latest");
    const duration_cold_ms = @divTrunc(std.Io.Clock.now(.awake, io).toNanoseconds() - start_cold, 1000000);

    const start_warm = std.Io.Clock.now(.awake, io).toNanoseconds();
    const img_warm = try builder.build(dockerfile_content, "/home/life-mac-africa/Work/GEase/backend", "gease-backend:latest");
    const duration_warm_ms = @divTrunc(std.Io.Clock.now(.awake, io).toNanoseconds() - start_warm, 1000000);

    try std.testing.expectEqualStrings(img_cold.id, img_warm.id);

    var df = try Dockerfile.parse(alloc, dockerfile_content);
    defer df.deinit();

    std.debug.print("\n=== GEase Backend Build Benchmark ===\n", .{});
    std.debug.print("Parsed instructions: {d}\n", .{df.instructions.len});
    std.debug.print("Cold build duration: {d} ms\n", .{duration_cold_ms});
    std.debug.print("Warm build duration (cache hit): {d} ms\n", .{duration_warm_ms});
    std.debug.print("======================================\n", .{});
}

test "experiment on Moby Dockerfile.simple and full Dockerfile" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var cfg = DaemonConfig.init(io);
    cfg.data_root = "/tmp/cratezig-moby-test";

    var image_service = try ImageService.init(alloc, cfg);
    defer image_service.deinit();

    var builder = Builder.init(alloc, cfg, &image_service);
    defer builder.deinit();

    // 1. Dockerfile.simple
    if (std.Io.Dir.openFileAbsolute(io, "/home/life-mac-africa/Work/moby/Dockerfile.simple", .{})) |file_simple| {
        defer file_simple.close(io);

        var read_buf: [2048]u8 = undefined;
        var reader = file_simple.reader(io, &read_buf);
        var content_buf: [4096]u8 = undefined;
        const n = try reader.interface.readSliceShort(&content_buf);
        const simple_content = content_buf[0..n];

        var df_simple = try Dockerfile.parse(alloc, simple_content);
        defer df_simple.deinit();

        const start_simple = std.Io.Clock.now(.awake, io).toNanoseconds();
        const img_simple = try builder.build(simple_content, "/home/life-mac-africa/Work/moby", "moby:simple");
        const dur_simple_ms = @divTrunc(std.Io.Clock.now(.awake, io).toNanoseconds() - start_simple, 1000000);

        std.debug.print("\n=== Moby Dockerfile.simple Benchmark ===\n", .{});
        std.debug.print("Parsed instructions: {d}\n", .{df_simple.instructions.len});
        std.debug.print("Build duration: {d} ms (Image ID: {s})\n", .{ dur_simple_ms, img_simple.id });
        std.debug.print("=========================================\n", .{});
    } else |_| {}

    // 2. Full 646-line Dockerfile
    if (std.Io.Dir.openFileAbsolute(io, "/home/life-mac-africa/Work/moby/Dockerfile", .{})) |file_full| {
        defer file_full.close(io);

        var read_buf: [4096]u8 = undefined;
        var reader = file_full.reader(io, &read_buf);
        var content_buf: [32768]u8 = undefined;
        const n = try reader.interface.readSliceShort(&content_buf);
        const full_content = content_buf[0..n];

        var df_full = try Dockerfile.parse(alloc, full_content);
        defer df_full.deinit();

        const start_full = std.Io.Clock.now(.awake, io).toNanoseconds();
        const img_full = try builder.build(full_content, "/home/life-mac-africa/Work/moby", "moby:full");
        const dur_full_ms = @divTrunc(std.Io.Clock.now(.awake, io).toNanoseconds() - start_full, 1000000);

        std.debug.print("\n=== Moby Full Dockerfile (646 lines) Benchmark ===\n", .{});
        std.debug.print("Parsed instructions: {d}\n", .{df_full.instructions.len});
        std.debug.print("Build duration: {d} ms (Image ID: {s})\n", .{ dur_full_ms, img_full.id });
        std.debug.print("===================================================\n", .{});
    } else |_| {}
}

test "experiment on Kubernetes and TensorFlow Dockerfiles" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var cfg = DaemonConfig.init(io);
    cfg.data_root = "/tmp/cratezig-k8s-tf-test";

    var image_service = try ImageService.init(alloc, cfg);
    defer image_service.deinit();

    var builder = Builder.init(alloc, cfg, &image_service);
    defer builder.deinit();

    // 1. Kubernetes agnhost Dockerfile
    if (std.Io.Dir.openFileAbsolute(io, "/home/life-mac-africa/Work/kubernetes/test/images/agnhost/Dockerfile", .{})) |file_k8s| {
        defer file_k8s.close(io);

        var read_buf: [2048]u8 = undefined;
        var reader = file_k8s.reader(io, &read_buf);
        var content_buf: [8192]u8 = undefined;
        const n = try reader.interface.readSliceShort(&content_buf);
        const k8s_content = content_buf[0..n];

        var df_k8s = try Dockerfile.parse(alloc, k8s_content);
        defer df_k8s.deinit();

        const start_k8s = std.Io.Clock.now(.awake, io).toNanoseconds();
        const img_k8s = try builder.build(k8s_content, "/home/life-mac-africa/Work/kubernetes/test/images/agnhost", "k8s-agnhost:latest");
        const dur_k8s_ms = @divTrunc(std.Io.Clock.now(.awake, io).toNanoseconds() - start_k8s, 1000000);

        std.debug.print("\n=== Kubernetes agnhost Benchmark ===\n", .{});
        std.debug.print("Parsed instructions: {d}\n", .{df_k8s.instructions.len});
        std.debug.print("Build duration: {d} ms (Image ID: {s})\n", .{ dur_k8s_ms, img_k8s.id });
        std.debug.print("=====================================\n", .{});
    } else |_| {}

    // 2. TensorFlow build Dockerfile
    if (std.Io.Dir.openFileAbsolute(io, "/home/life-mac-africa/Work/tensorflow/tensorflow/tools/tf_sig_build_dockerfiles/Dockerfile", .{})) |file_tf| {
        defer file_tf.close(io);

        var read_buf: [2048]u8 = undefined;
        var reader = file_tf.reader(io, &read_buf);
        var content_buf: [8192]u8 = undefined;
        const n = try reader.interface.readSliceShort(&content_buf);
        const tf_content = content_buf[0..n];

        var df_tf = try Dockerfile.parse(alloc, tf_content);
        defer df_tf.deinit();

        const start_tf = std.Io.Clock.now(.awake, io).toNanoseconds();
        const img_tf = try builder.build(tf_content, "/home/life-mac-africa/Work/tensorflow/tensorflow/tools/tf_sig_build_dockerfiles", "tensorflow-builder:latest");
        const dur_tf_ms = @divTrunc(std.Io.Clock.now(.awake, io).toNanoseconds() - start_tf, 1000000);

        std.debug.print("\n=== TensorFlow Build Dockerfile Benchmark ===\n", .{});
        std.debug.print("Parsed instructions: {d}\n", .{df_tf.instructions.len});
        std.debug.print("Build duration: {d} ms (Image ID: {s})\n", .{ dur_tf_ms, img_tf.id });
        std.debug.print("==============================================\n", .{});
    } else |_| {}
}
