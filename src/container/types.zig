//! Plain data types describing a container's configuration and state,
//! with Docker-compatible JSON encodings.
const std = @import("std");
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
        try jws.objectField("Privileged");
        try jws.write(self.privleged);
        try jws.objectField("CapAdd");
        try jws.write(self.cap_add);
        try jws.objectField("CapDrop");
        try jws.write(self.cap_drop);
        try jws.objectField("ReadonlyRootfs");
        try jws.write(self.read_only_rootfs);
        try jws.objectField("ShmSize");
        try jws.write(self.shm_size);
        try jws.objectField("Init");
        try jws.write(self.init);
        try jws.objectField("RestartPolicy");
        try jws.beginObject();
        try jws.objectField("Name");
        try jws.write(self.restart_policy.dockerName());
        try jws.objectField("MaximumRetryCount");
        try jws.write(self.restart_policy.maximum_retry_count);
        try jws.endObject();
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

    pub fn jsonStringify(self: ContainerState, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Status");
        try jws.write(@tagName(self.status));
        try jws.objectField("Running");
        try jws.write(self.running);
        try jws.objectField("Paused");
        try jws.write(self.paused);
        try jws.objectField("Restarting");
        try jws.write(self.restarting);
        try jws.objectField("OOMKilled");
        try jws.write(self.oom_killed);
        try jws.objectField("Dead");
        try jws.write(self.dead);
        try jws.objectField("Pid");
        try jws.write(self.pid);
        try jws.objectField("ExitCode");
        try jws.write(self.exit_code);
        try jws.objectField("StartedAt");
        try jws.write(self.started_at);
        try jws.objectField("FinishedAt");
        try jws.write(self.finished_at);
        try jws.endObject();
    }
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


pub const PortBinding = struct {
    host_ip: []const u8 = "0.0.0.0",
    host_port: []const u8,

    pub fn jsonStringify(self: PortBinding, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("HostIp");
        try jws.write(self.host_ip);
        try jws.objectField("HostPort");
        try jws.write(self.host_port);
        try jws.endObject();
    }
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

    /// Docker spells these with dashes: "on-failure", "unless-stopped".
    pub fn dockerName(self: RestartPolicy) []const u8 {
        return switch (self.name) {
            .no => "no",
            .always => "always",
            .on_failure => "on-failure",
            .unless_stopped => "unless-stopped",
        };
    }

    pub fn parseName(s: []const u8) Name {
        if (std.mem.eql(u8, s, "always")) return .always;
        if (std.mem.eql(u8, s, "on-failure")) return .on_failure;
        if (std.mem.eql(u8, s, "unless-stopped")) return .unless_stopped;
        return .no;
    }
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
