const std = @import("std");
const Config = @import("../config/config.zig").DaemonConfig;
const ContainerStore = @import("../container/store.zig").ContainerStore;
const Events = @import("../events/events.zig").Events;
const ImageService = @import("../image/service.zig").ImageService;
const NetController = @import("../network/controller.zig").NetworkController;
const VolumeService = @import("../volume/service.zig").VolumeService;

pub const Daemon = struct {
    allocator: std.mem.Allocator,

    /// Loaded from /etc/docker/daemon.json at startup (mostly immutable)
    config: Config,

    /// All containers — the source of truth for what exists
    containers: ContainerStore,

    /// Event ring buffer — publish here after every lifecycle change
    events: Events,

    /// Image operations (pull, layer management, writable layer creation)
    images: ImageService,

    /// Network operations (bridge, veth, iptables, IPAM)
    network: NetController,

    /// Volume operations (create/mount/unmount)
    volumes: VolumeService,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Daemon {
        var d = Daemon{
            .allocator = allocator,
            .config = config,
            .containers = ContainerStore.init(allocator, config.io),
            .events = Events.init(allocator, config.io),
            .images = try ImageService.init(allocator, config),
            .network = try NetController.init(allocator, config),
            .volumes = try VolumeService.init(allocator, config),
        };

        // Step 1: Create data directories
        try d.setupDataDirectories();

        // Step 2: Load existing containers from disk
        try d.containers.loadFromDisk(config.data_root, allocator);

        // Step 3: Initialize networking (creates docker0 bridge etc.)
        try d.network.setup();

        return d;
    }

    pub fn deinit(self: *Daemon) void {
        self.containers.deinit();
        self.events.deinit();
        self.images.deinit();
        self.network.deinit();
        self.volumes.deinit();
    }

    fn setupDataDirectories(self: *Daemon) !void {
        const dirs = [_][]const u8{
            "/containers",                    "/image/overlay2/imagedb/content/sha256",
            "/image/overlay2/layerdb/sha256", "/overlay2/l",
            "/volumes",                       "/network/files",
        };
        for (dirs) |suffix| {
            var buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}{s}", .{ self.config.data_root, suffix });
            std.Io.Dir.createDirAbsolute(self.config.io, path, .default_dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
    }

    pub const containerCreate = @import("create.zig").containerCreate;
    pub const containerStart = @import("start.zig").containerStart;
    pub const containerStop = @import("stop.zig").containerStop;
    pub const containerRemove = @import("remove.zig").containerRemove;
};
