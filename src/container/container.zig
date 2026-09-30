const std = @import("std");

const DaemonConfig = @import("../config/config.zig").DaemonConfig;
const fsutil = @import("../util/fsutil.zig");
const types = @import("types.zig");

pub const ContainerConfig = types.ContainerConfig;
pub const HostConfig = types.HostConfig;
pub const ContainerState = types.ContainerState;
pub const NetworkSettings = types.NetworkSettings;
pub const EndpointSettings = types.EndpointSettings;
pub const PortBinding = types.PortBinding;
pub const MountPoint = types.MountPoint;
pub const RestartPolicy = types.RestartPolicy;
pub const LogConfig = types.LogConfig;
pub const HealthCheckConfig = types.HealthCheckConfig;
pub const HealthState = types.HealthState;
pub const ExecProcess = types.ExecProcess;

pub const Container = struct {
    io: std.Io,

    /// Owns every string, slice and map hanging off this container. The
    /// container must never reference request-scoped memory.
    arena: std.heap.ArenaAllocator,

    /// Set by an explicit stop/kill so the restart policy leaves it down.
    restart_suppressed: bool = false,
    /// Consecutive policy restarts; drives exponential backoff.
    restart_count: u32 = 0,

    id: [64]u8,
    id_short: [12]u8,
    name: []const u8,
    created_at: i64,

    config: ContainerConfig,
    host_config: HostConfig,

    image_id: []const u8, // sha256:... digest
    image_name: []const u8, // "ubuntu:22.04"

    rw_layer_id: []const u8,
    rootfs_paths: []const u8,

    mutex: std.Io.Mutex = .init,
    state: ContainerState = .{},

    network_settings: NetworkSettings,

    log_path: []const u8 = "",
    log_driver: []const u8 = "json-file",

    exec_commands: std.StringHashMap(*ExecProcess),

    pub fn jsonStringify(self: Container, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Id");
        try jws.write(&self.id);
        try jws.objectField("IdShort");
        try jws.write(&self.id_short);
        try jws.objectField("Name");
        try jws.write(self.name);
        try jws.objectField("Created");
        try jws.write(self.created_at);
        try jws.objectField("Config");
        try jws.write(self.config);
        try jws.objectField("HostConfig");
        try jws.write(self.host_config);
        try jws.objectField("Image");
        try jws.write(self.image_id);
        try jws.objectField("ImageName");
        try jws.write(self.image_name);
        try jws.objectField("RwLayerID");
        try jws.write(self.rw_layer_id);
        try jws.objectField("RootfsPath");
        try jws.write(self.rootfs_paths);
        try jws.objectField("State");
        try jws.write(self.state);
        try jws.objectField("NetworkSettings");
        try jws.write(self.network_settings);
        try jws.objectField("LogPath");
        try jws.write(self.log_path);
        try jws.objectField("LogDriver");
        try jws.write(self.log_driver);
        try jws.endObject();
    }

    /// Allocates an empty container whose memory is owned by its own arena.
    pub fn create(gpa: std.mem.Allocator, io: std.Io) !*Container {
        const ctr = try gpa.create(Container);
        ctr.* = .{
            .io = io,
            .arena = .init(gpa),
            .id = @splat(0),
            .id_short = @splat(0),
            .name = "",
            .created_at = 0,
            .config = .{ .image = "", .labels = undefined },
            .host_config = .{ .port_bindings = undefined },
            .image_id = "",
            .image_name = "",
            .rw_layer_id = "",
            .rootfs_paths = "",
            .network_settings = .{ .networks = undefined, .ports = undefined },
            .exec_commands = undefined,
        };
        const a = ctr.arena.allocator();
        ctr.config.labels = .init(a);
        ctr.host_config.port_bindings = .init(a);
        ctr.network_settings = .{ .networks = .init(a), .ports = .init(a) };
        ctr.exec_commands = .init(a);
        return ctr;
    }

    pub fn allocator(self: *Container) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Frees the container and everything it owns.
    pub fn destroy(self: *Container, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn lock(self: *Container) void {
        self.mutex.lockUncancelable(self.io);
    }

    pub fn unlock(self: *Container) void {
        self.mutex.unlock(self.io);
    }

    pub fn isRunning(self: *Container) bool {
        self.mutex.lockUncancelable(self.io);

        defer self.mutex.unlock(self.io);

        return self.state.running;
    }

    pub fn isRemoving(self: *Container) bool {
        self.mutex.lockUncancelable(self.io);

        defer self.mutex.unlock(self.io);

        return self.state.status == .removing;
    }

    pub fn persistState(self: *Container, cfg: *const DaemonConfig) !void {
        var path_buf: [512]u8 = undefined;
        const dir = cfg.containerDir(&self.id, &path_buf);
        try std.Io.Dir.createDirPath(.cwd(), self.io, dir);

        var state_path_buf: [512]u8 = undefined;
        const state_path = try std.fmt.bufPrint(&state_path_buf, "{s}/config.v2.json", .{dir});

        const id_slice = std.mem.sliceTo(&self.id, 0);

        const SerializableContainer = struct {
            ID: []const u8,
            Name: []const u8,
            Created: i64,
            Image: []const u8,
            ImageName: []const u8,
            RwLayerID: []const u8,
            RootfsPath: []const u8,
            LogPath: []const u8,
            LogDriver: []const u8,
            State: ContainerState,
            Config: ContainerConfig,
            HostConfig: HostConfig,
        };

        const sc = SerializableContainer{
            .ID = id_slice,
            .Name = self.name,
            .Created = self.created_at,
            .Image = self.image_id,
            .ImageName = self.image_name,
            .RwLayerID = self.rw_layer_id,
            .RootfsPath = self.rootfs_paths,
            .LogPath = self.log_path,
            .LogDriver = self.log_driver,
            .State = self.state,
            .Config = self.config,
            .HostConfig = self.host_config,
        };

        // Transient buffer; page_allocator is thread-safe and keeps this
        // off the container arena.
        try fsutil.writeJsonAtomic(self.io, std.heap.page_allocator, state_path, sc);
    }
};
