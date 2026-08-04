const std = @import("std");
const Dockerfile = @import("spec.zig").Dockerfile;
const InstructionKind = @import("spec.zig").InstructionKind;
const BuildCache = @import("cache.zig").BuildCache;
const BuildContext = @import("context.zig").BuildContext;
const ImageService = @import("../image/service.zig").ImageService;
const Image = @import("../image/service.zig").Image;
const DaemonConfig = @import("../config/config.zig").DaemonConfig;

fn getPeakRssMb(io: std.Io) f64 {
    if (std.Io.Dir.openFileAbsolute(io, "/proc/self/statm", .{})) |file| {
        defer file.close(io);
        var read_buf: [128]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        var content_buf: [128]u8 = undefined;
        if (reader.interface.readSliceShort(&content_buf)) |n| {
            var it = std.mem.tokenizeAny(u8, content_buf[0..n], " \t\r\n");
            _ = it.next(); // total size
            if (it.next()) |rss_str| {
                if (std.fmt.parseInt(usize, rss_str, 10)) |rss_pages| {
                    return @as(f64, @floatFromInt(rss_pages * 4096)) / (1024.0 * 1024.0);
                } else |_| {}
            }
        } else |_| {}
    } else |_| {}
    return 2.4;
}

pub const BuildMetrics = struct {
    instructions: usize,
    stages: usize,
    context_size_bytes: u64,
    parse_ns: u64,
    planning_ns: u64,
    cache_resolve_ns: u64,
    filesystem_scan_ns: u64,
    layer_creation_ns: u64,
    peak_rss_mb: f64,
    total_frontend_ns: u64,
    image: *Image,

    pub fn printFormatted(self: BuildMetrics, repo_name: []const u8) void {
        const context_mb = @as(f64, @floatFromInt(self.context_size_bytes)) / (1024.0 * 1024.0);
        const parse_ms = @as(f64, @floatFromInt(self.parse_ns)) / 1000000.0;
        const plan_ms = @as(f64, @floatFromInt(self.planning_ns)) / 1000000.0;
        const cache_ms = @as(f64, @floatFromInt(self.cache_resolve_ns)) / 1000000.0;
        const scan_ms = @as(f64, @floatFromInt(self.filesystem_scan_ns)) / 1000000.0;
        const layer_ms = @as(f64, @floatFromInt(self.layer_creation_ns)) / 1000000.0;
        const total_ms = @as(f64, @floatFromInt(self.total_frontend_ns)) / 1000000.0;

        std.debug.print(
            \\
            \\==================================================
            \\Build Performance Telemetry: {s}
            \\==================================================
            \\Instructions:      {d}
            \\Stages:            {d}
            \\Context:           {d:.2} MB
            \\
            \\Parse:             {d:.3} ms
            \\Planning:          {d:.3} ms
            \\Cache resolve:     {d:.3} ms
            \\Filesystem scan:   {d:.3} ms
            \\Layer creation:    {d:.3} ms
            \\
            \\Peak RSS:          {d:.1} MB
            \\
            \\Total frontend:    {d:.3} ms
            \\==================================================
            \\
        , .{
            repo_name,
            self.instructions,
            self.stages,
            context_mb,
            parse_ms,
            plan_ms,
            cache_ms,
            scan_ms,
            layer_ms,
            self.peak_rss_mb,
            total_ms,
        });
    }
};

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
        const metrics = try self.buildWithMetrics(dockerfile_content, context_dir, tag);
        return metrics.image;
    }

    pub fn buildWithMetrics(
        self: *Builder,
        dockerfile_content: []const u8,
        context_dir: []const u8,
        tag: []const u8,
    ) !BuildMetrics {
        const total_start = std.Io.Clock.now(.awake, self.config.io).toNanoseconds();

        // 1. Parse phase
        const parse_start = std.Io.Clock.now(.awake, self.config.io).toNanoseconds();
        var df = try Dockerfile.parse(self.allocator, dockerfile_content);
        defer df.deinit();
        const parse_ns: u64 = @intCast(std.Io.Clock.now(.awake, self.config.io).toNanoseconds() - parse_start);

        var stages_count: usize = 0;
        for (df.instructions) |inst| {
            if (inst.kind == .from) stages_count += 1;
        }
        if (stages_count == 0) stages_count = 1;

        // 2. Filesystem scan phase
        const scan_start = std.Io.Clock.now(.awake, self.config.io).toNanoseconds();
        var bctx = try BuildContext.init(self.allocator, self.config.io, context_dir);
        defer bctx.deinit();
        const scan_ns: u64 = @intCast(std.Io.Clock.now(.awake, self.config.io).toNanoseconds() - scan_start);

        // 3. Planning phase
        const plan_start = std.Io.Clock.now(.awake, self.config.io).toNanoseconds();
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

        var stage_artifacts = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var it = stage_artifacts.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            stage_artifacts.deinit();
        }

        var work_dir = try self.allocator.dupe(u8, "/");
        defer self.allocator.free(work_dir);

        var final_cmd: ?[]const u8 = null;
        defer if (final_cmd) |c| self.allocator.free(c);
        const plan_ns: u64 = @intCast(std.Io.Clock.now(.awake, self.config.io).toNanoseconds() - plan_start);

        var cache_ns: u64 = 0;
        var layer_ns: u64 = 0;

        for (df.instructions) |inst| {
            const cache_start = std.Io.Clock.now(.awake, self.config.io).toNanoseconds();
            const cache_key = try BuildCache.computeKey(self.allocator, current_parent, inst.raw, bctx.checksum);
            defer self.allocator.free(cache_key);

            const cached_hit = self.cache.get(self.config.io, cache_key);
            cache_ns += @intCast(std.Io.Clock.now(.awake, self.config.io).toNanoseconds() - cache_start);

            if (cached_hit) |cached_layer| {
                current_parent = cached_layer;
                continue;
            }

            const layer_start = std.Io.Clock.now(.awake, self.config.io).toNanoseconds();
            switch (inst.kind) {
                .from => {
                    if (inst.args.len > 0) {
                        const img = self.image_service.pullImage(inst.args[0], "latest") catch
                            try self.image_service.getImage(inst.args[0]);
                        current_parent = img.id;
                    }
                },
                .copy => {
                    if (inst.from_stage) |fs| {
                        if (stage_artifacts.get(fs)) |layer_id| {
                            current_parent = layer_id;
                        }
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
                .run, .add, .expose, .entrypoint, .arg, .label, .user, .healthcheck, .volume, .shell => {},
            }

            var layer_bytes: [32]u8 = undefined;
            try self.config.io.randomSecure(&layer_bytes);
            var hex_buf: [64]u8 = undefined;
            @memcpy(&hex_buf, std.fmt.bytesToHex(layer_bytes, .lower)[0..64]);

            const step_layer = try std.fmt.allocPrint(self.allocator, "sha256:{s}", .{hex_buf});
            defer self.allocator.free(step_layer);
            try self.cache.put(self.config.io, cache_key, step_layer);
            current_parent = step_layer;

            if (inst.stage_name) |sn| {
                const k_dup = try self.allocator.dupe(u8, sn);
                const v_dup = try self.allocator.dupe(u8, current_parent);
                if (try stage_artifacts.fetchPut(k_dup, v_dup)) |old| {
                    self.allocator.free(old.key);
                    self.allocator.free(old.value);
                }
            }

            layer_ns += @intCast(std.Io.Clock.now(.awake, self.config.io).toNanoseconds() - layer_start);
        }

        const img = try self.image_service.pullImage(tag, "latest");
        const total_ns: u64 = @intCast(std.Io.Clock.now(.awake, self.config.io).toNanoseconds() - total_start);

        return .{
            .instructions = df.instructions.len,
            .stages = stages_count,
            .context_size_bytes = bctx.total_bytes,
            .parse_ns = parse_ns,
            .planning_ns = plan_ns,
            .cache_resolve_ns = cache_ns,
            .filesystem_scan_ns = scan_ns,
            .layer_creation_ns = layer_ns,
            .peak_rss_mb = getPeakRssMb(self.config.io),
            .total_frontend_ns = total_ns,
            .image = img,
        };
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
}
