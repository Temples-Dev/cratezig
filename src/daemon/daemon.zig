const std = @import("std");
const Config = @import("../config/config.zig").DaemonConfig;
const ContainerStore = @import("../container/store.zig").ContainerStore;
const Events = @import("../events/events.zig").Events;
const ImageService = @import("../image/service.zig").ImageService;
const NetController = @import("../network/controller.zig").NetworkController;
const VolumeService = @import("../volume/service.zig").VolumeService;
const runc = @import("../runtime/runc.zig");

pub const Daemon = struct {
    allocator: std.mem.Allocator,

    /// Loaded from /etc/cratezig/daemon.json at startup (mostly immutable)
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

    /// "<exec_root>/runc", handed to the runc wrapper.
    runc_root: []const u8,

    /// Heap-allocates the daemon. Services keep pointers into it, so it
    /// must never be copied or moved after this call.
    pub fn create(allocator: std.mem.Allocator, config: Config) !*Daemon {
        try setupDirectories(config.io, config.data_root, config.exec_root);

        const d = try allocator.create(Daemon);
        errdefer allocator.destroy(d);
        d.runc_root = try std.fmt.allocPrint(allocator, "{s}/runc", .{config.exec_root});
        errdefer allocator.free(d.runc_root);
        runc.configure(config.runc_path, d.runc_root);

        d.allocator = allocator;
        d.config = config;
        d.containers = ContainerStore.init(allocator, config.io);
        errdefer d.containers.deinit();
        d.events = Events.init(allocator, config.io);
        errdefer d.events.deinit();
        d.images = try ImageService.init(allocator, config);
        errdefer d.images.deinit();
        d.network = try NetController.init(allocator, config);
        errdefer d.network.deinit();
        d.volumes = try VolumeService.init(allocator, config);
        errdefer d.volumes.deinit();

        try d.containers.loadFromDisk(config.data_root, allocator);
        try d.network.setup();
        return d;
    }

    pub fn destroy(self: *Daemon) void {
        self.containers.deinit();
        self.events.deinit();
        self.images.deinit();
        self.network.deinit();
        self.volumes.deinit();
        self.allocator.free(self.runc_root);
        self.allocator.destroy(self);
    }

    fn setupDirectories(io: std.Io, data_root: []const u8, exec_root: []const u8) !void {
        const dirs = [_][]const u8{
            "",                                       "/containers",
            "/image/overlay2/imagedb/content/sha256", "/image/overlay2/layerdb/sha256",
            "/overlay2/l",                            "/volumes",
            "/network/files",
        };
        for (dirs) |suffix| {
            var buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}{s}", .{ data_root, suffix });
            try std.Io.Dir.createDirPath(.cwd(), io, path);
        }
        for ([_][]const u8{ "/runc", "/bundles" }) |suffix| {
            var buf: [512]u8 = undefined;
            try std.Io.Dir.createDirPath(.cwd(), io, try std.fmt.bufPrint(&buf, "{s}{s}", .{ exec_root, suffix }));
        }
    }

    pub const containerCreate = @import("create.zig").containerCreate;
    pub const containerStart = @import("start.zig").containerStart;
    pub const containerStop = @import("stop.zig").containerStop;
    pub const containerRemove = @import("remove.zig").containerRemove;
    pub const containerRestart = @import("restart.zig").containerRestart;
    pub const containerKill = @import("kill.zig").containerKill;
    pub const containerPause = @import("pause.zig").containerPause;
    pub const containerUnpause = @import("pause.zig").containerUnpause;
    pub const containerWait = @import("wait.zig").containerWait;
    pub const containerPrune = @import("prune.zig").containerPrune;
    pub const containerLogs = @import("logs.zig").containerLogs;
    pub const containerStats = @import("stats.zig").containerStats;
    pub const containerExecCreate = @import("exec.zig").containerExecCreate;
    pub const containerExecStart = @import("exec.zig").containerExecStart;
    pub const containerExecInspect = @import("exec.zig").containerExecInspect;
};
