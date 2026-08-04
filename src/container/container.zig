const std = @import("std");

const DaemonConfig = @import("../config/config.zig").DaemonConfig;
const PrivilegeLevel = @import("../runtime/privilege.zig").PrivilegeLevel;

pub const ContainerConfig = struct {
    image: []const u8,

    cmd: []const []const u8 = &.{},

    entrypoint: []const []const u8 = &.{},

    ///Environment variables: ["KEY=value","K:V"]
    env: []const []const u8 = &.{},

    /// Working directory inside the container
    working_dir: []const u8 = "/",

    // username
    user: []const u8 = "",

    tty: bool = false,

    open_stdin: bool = false,

    /// Signal to send on docker stop
    stop_signal: []const u8 = "SIGTERM",

    stop_timeout: u32 = 10,

    privilege_level: PrivilegeLevel = .standard,

    labels: std.StringHashMap([]const u8),

    healthcheck: ?HealthCheckConfig = null,

    pub fn jsonStringify(self: ContainerConfig, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Image");
        try jws.write(self.image);
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
        try jws.objectField("Tty");
        try jws.write(self.tty);
        try jws.objectField("OpenStdin");
        try jws.write(self.open_stdin);
        try jws.objectField("StopSignal");
        try jws.write(self.stop_signal);
        try jws.objectField("StopTimeout");
        try jws.write(self.stop_timeout);
        
        try jws.objectField("Labels");
        try jws.beginObject();
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            try jws.objectField(entry.key_ptr.*);
            try jws.write(entry.value_ptr.*);
        }
        try jws.endObject();
        
        if (self.healthcheck) |hc| {
            try jws.objectField("Healthcheck");
            try jws.write(hc);
        }
        try jws.endObject();
    }
};

pub const HostConfig = struct {
    memory: i64 = 0,

    memory_swap: i64 = 0,

    cpu_shares: i64 = 0,

    cpu_quota: i64 = 0,

    cpu_period: i64 = 100_1000,

    pid_limits: i64 = 0,

    // Port mapping. Key: "80/tcp", Value: [{host_ip, host_port}]
    port_bindings: std.StringHashMap([]PortBinding),

    binds: []const []const u8 = &.{},

    mounts: []const []const u8 = &.{},

    //Networking
    network_mode: []const u8 = "bridge",
    dns: []const []const u8 = &.{},
    extra_hosts: []const []const u8 = &.{},

    // Security
    privleged: bool = false,
    cap_add: []const []const u8 = &.{},
    cap_drop: []const []const u8 = &.{},
    read_only_rootfs: bool = false,

    // Runtime
    shm_size: i64 = 67_108_864,
    init: bool = false,
    restart_policy: RestartPolicy = .{},

    ipc_mode: []const u8 = "private",
    pid_mode: []const u8 = "",

    pub fn jsonStringify(self: HostConfig, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Memory");
        try jws.write(self.memory);
        try jws.objectField("MemorySwap");
        try jws.write(self.memory_swap);
        try jws.objectField("CpuShares");
        try jws.write(self.cpu_shares);
        try jws.objectField("CpuQuota");
        try jws.write(self.cpu_quota);
        try jws.objectField("CpuPeriod");
        try jws.write(self.cpu_period);
        try jws.objectField("PidLimits");
        try jws.write(self.pid_limits);
        
        try jws.objectField("PortBindings");
        try jws.beginObject();
        var it = self.port_bindings.iterator();
        while (it.next()) |entry| {
            try jws.objectField(entry.key_ptr.*);
            try jws.write(entry.value_ptr.*);
        }
        try jws.endObject();
        
        try jws.objectField("Binds");
        try jws.write(self.binds);
        try jws.objectField("Mounts");
        try jws.write(self.mounts);
        try jws.objectField("NetworkMode");
        try jws.write(self.network_mode);
        try jws.objectField("Dns");
        try jws.write(self.dns);
        try jws.objectField("ExtraHosts");
        try jws.write(self.extra_hosts);
        try jws.objectField("Privleged");
        try jws.write(self.privleged);
        try jws.objectField("CapAdd");
        try jws.write(self.cap_add);
        try jws.objectField("CapDrop");
        try jws.write(self.cap_drop);
        try jws.objectField("ReadOnlyRootfs");
        try jws.write(self.read_only_rootfs);
        try jws.objectField("ShmSize");
        try jws.write(self.shm_size);
        try jws.objectField("Init");
        try jws.write(self.init);
        try jws.objectField("RestartPolicy");
        try jws.write(self.restart_policy);
        try jws.objectField("IpcMode");
        try jws.write(self.ipc_mode);
        try jws.objectField("PidMode");
        try jws.write(self.pid_mode);
        try jws.endObject();
    }
};

pub const ContainerState = struct {
    pub const Status = enum {
        created,
        running,
        paused,
        restarting,
        removing,
        exited,
        dead,

        pub fn toString(self: Status) []const u8 {
            return @tagName(self);
        }
    };

    status: Status = .created,
    running: bool = false,
    paused: bool = false,
    restarting: bool = false,
    oom_killed: bool = false,
    dead: bool = false,

    /// Host PID of the containers init process. O when not running
    pid: u32 = 0,

    exit_code: i32 = 0,

    started_at: i64 = 0,
    finished_at: i64 = 0,

    health: ?HealthState = null,
};

pub const NetworkSettings = struct {
    networks: std.StringHashMap(EndpointSettings),
    ports: std.StringHashMap([]PortBinding),

    pub fn jsonStringify(self: NetworkSettings, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Networks");
        try jws.beginObject();
        var it_net = self.networks.iterator();
        while (it_net.next()) |entry| {
            try jws.objectField(entry.key_ptr.*);
            try jws.write(entry.value_ptr.*);
        }
        try jws.endObject();
        
        try jws.objectField("Ports");
        try jws.beginObject();
        var it_port = self.ports.iterator();
        while (it_port.next()) |entry| {
            try jws.objectField(entry.key_ptr.*);
            try jws.write(entry.value_ptr.*);
        }
        try jws.endObject();
        try jws.endObject();
    }
};

pub const EndpointSettings = struct { network_id: []const u8 = "", endpoint_id: []const u8 = "", gateway: []const u8 = "", ip_address: []const u8 = "", ip_prefix_len: u8 = 0, mac_address: []const u8 = "", aliases: []const []const u8 = &.{} };

pub const Container = struct {
    io: std.Io,

    id: [64]u8,
    id_short: [12]u8,
    name: []u8,
    created_at: i64,

    config: ContainerConfig,
    host_config: HostConfig,

    image_id: []u8, // sha256:... digest
    image_name: []u8, // "ubuntu:22.04"

    rw_layer_id: []u8,
    rootfs_paths: []u8,

    mutex: std.Io.Mutex = .init,
    state: ContainerState = .{},

    network_settings: NetworkSettings,

    log_path: []u8 = "",
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

    pub fn init(io: std.Io) Container {
        return .{ .io = io };
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

        try std.Io.Dir.createDirAbsolute(self.io, dir, .default_dir);

        var state_path_buf: [512]u8 = undefined;

        const state_path = try std.fmt.bufPrint(&state_path_buf, "{s}/config.v2.json", .{dir});

        const file = try std.Io.Dir.createFileAbsolute(self.io, state_path, .{});
        defer file.close(self.io);

        var write_buf: [4096]u8 = undefined;
        var file_writer = file.writer(self.io, &write_buf);
        try std.json.Stringify.value(self.state, .{}, &file_writer.interface);
    }
};

pub const PortBinding = struct {
    host_ip: []const u8 = "0.0.0.0",
    host_port: []const u8,
};

pub const MountPoint = struct {
    pub const MountType = enum {
        bind,
        volume,
        tmpfs,
        npipe,
    };

    mount_type: MountType,
    source: []const u8,
    desination: []const u8,
    mode: []const u8 = "rw",
    rw: bool = true,
    propagation: []const u8 = "rprivate",
    name: []const u8 = "",
};

pub const RestartPolicy = struct {
    pub const Name = enum { no, always, on_failure, unless_stopped };

    name: Name = .no,
    maximum_retry_count: u32 = 0,
};

pub const LogConfig = struct { log_type: []const u8 = "json-file", config: std.StringHashMap([]const u8) };

pub const HealthCheckConfig = struct {
    health_test: []const []const u8,
    interval: i64 = 30_000_000_000, // 30s
    timeout: i64 = 30_000_000_000,
    retries: u32 = 3,
    start_period: i64 = 0,
};

pub const HealthState = struct {
    pub const Status = enum { starting, healthy, unhealthy, none };

    status: Status = .none,
    failing_streak: u32 = 0,
};

pub const ExecProcess = struct {
    id: []u8, //
    running: bool = true,
    exit_code: i32 = 0,
    pid: u32 = 0,
    tty: bool = false,
    container_id: []u8,
    cmd: []const []const u8,
    privileged: bool = false,
};
