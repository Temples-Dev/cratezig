const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const Container = @import("../container/container.zig").Container;
const ContainerConfig = @import("../container/container.zig").ContainerConfig;
const HostConfig = @import("../container/container.zig").HostConfig;
const Event = @import("../events/events.zig").Event;
const CrateError = @import("../errdefs/errors.zig").Error;
const EndpointSettings = @import("../container/container.zig").EndpointSettings;
const PortBinding = @import("../container/container.zig").PortBinding;
const ExecProcess = @import("../container/container.zig").ExecProcess;

pub const CreateConfig = struct {
    config: ContainerConfig,
    host_config: HostConfig,
    name: ?[]const u8 = null,
};

pub const CreateResponse = struct {
    id: [64]u8,
    warnings: [][]const u8,
};

pub fn containerCreate(daemon: *Daemon, params: CreateConfig, allocator: std.mem.Allocator) !CreateResponse {
    const image = try daemon.images.getImage(params.config.image);

    if (params.config.cmd.len == 0 and image.config.cmd.len == 0 and
        params.config.entrypoint.len == 0 and image.config.entrypoint.len == 0)
    {
        return CrateError.NoCommandSpecified;
    }

    var id: [64]u8 = undefined;
    try generateRandomHexID(daemon.config.io, &id);

    var name_buf: [64]u8 = undefined;
    const name = params.name orelse try generateRandomName(daemon.config.io, &name_buf);

    if (daemon.containers.get(name) != null) {
        return CrateError.ContainerNameInUse;
    }

    const merged_config = mergeConfig(image.config, params.config);

    try daemon.images.createWritableLayer(&id, image.id);

    const now = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds();
    const ctr = try allocator.create(Container);

    ctr.* = .{
        .io = daemon.config.io,
        .id = id,
        .id_short = id[0..12].*,
        .name = try allocator.dupe(u8, name),
        .created_at = @intCast(now),
        .config = merged_config,
        .host_config = params.host_config,
        .image_id = try allocator.dupe(u8, image.id),
        .image_name = try allocator.dupe(u8, params.config.image),
        .rw_layer_id = try allocator.dupe(u8, &id),
        .rootfs_paths = try allocator.dupe(u8, ""),
        .network_settings = .{
            .networks = std.StringHashMap(EndpointSettings).init(allocator),
            .ports = std.StringHashMap([]PortBinding).init(allocator),
        },
        .exec_commands = std.StringHashMap(*ExecProcess).init(allocator),
    };

    try ctr.persistState(&daemon.config);
    try daemon.containers.add(ctr);

    daemon.events.publish(.{
        .event_type = .container,
        .action = "create",
        .actor_id = &id,
        .actor_attrs = buildAttrs(allocator, ctr),
        .time_nano = now,
    });

    return CreateResponse{
        .id = id,
        .warnings = &.{},
    };
}

fn generateRandomHexID(io: std.Io, out: *[64]u8) !void {
    var bytes: [32]u8 = undefined;
    try io.randomSecure(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    @memcpy(out, &hex);
}

fn generateRandomName(io: std.Io, buf: *[64]u8) ![]u8 {
    var bytes: [4]u8 = undefined;
    try io.randomSecure(&bytes);
    const n = std.mem.readInt(u32, &bytes, .little);
    return std.fmt.bufPrint(buf, "/container_{d}", .{n}) catch unreachable;
}

fn mergeConfig(image_cfg: anytype, user_cfg: ContainerConfig) ContainerConfig {
    return ContainerConfig{
        .image = user_cfg.image,
        .cmd = if (user_cfg.cmd.len > 0) user_cfg.cmd else image_cfg.cmd,
        .entrypoint = if (user_cfg.entrypoint.len > 0) user_cfg.entrypoint else image_cfg.entrypoint,
        .env = user_cfg.env, // image env is prepended by start.zig
        .working_dir = if (user_cfg.working_dir.len > 0) user_cfg.working_dir else image_cfg.working_dir,
        .user = if (user_cfg.user.len > 0) user_cfg.user else image_cfg.user,
        .tty = user_cfg.tty,
        .open_stdin = user_cfg.open_stdin,
        .stop_signal = user_cfg.stop_signal,
        .stop_timeout = user_cfg.stop_timeout,
        .labels = user_cfg.labels,
        .healthcheck = user_cfg.healthcheck,
    };
}

fn buildAttrs(allocator: std.mem.Allocator, ctr: *Container) std.StringHashMap([]const u8) {
    var attrs = std.StringHashMap([]const u8).init(allocator);
    attrs.put("name", ctr.name) catch {};
    attrs.put("image", ctr.image_name) catch {};
    attrs.put("imageID", ctr.image_id) catch {};
    return attrs;
}
