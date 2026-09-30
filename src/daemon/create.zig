const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const Container = @import("../container/container.zig").Container;
const ContainerConfig = @import("../container/container.zig").ContainerConfig;
const HostConfig = @import("../container/container.zig").HostConfig;
const clone = @import("../container/clone.zig");
const CrateError = @import("../errdefs/errors.zig").Error;

pub const CreateConfig = struct {
    config: ContainerConfig,
    host_config: HostConfig,
    name: ?[]const u8 = null,
};

pub const CreateResponse = struct {
    id: [64]u8,
    warnings: [][]const u8,
};

/// Creates a container. `params` may point at request-scoped memory: every
/// field is deep-copied into the container's own arena.
pub fn containerCreate(daemon: *Daemon, params: CreateConfig) !CreateResponse {
    const image = try daemon.images.getImage(params.config.image);

    if (params.config.cmd.len == 0 and image.config.cmd.len == 0 and
        params.config.entrypoint.len == 0 and image.config.entrypoint.len == 0)
    {
        return CrateError.NoCommandSpecified;
    }

    var id: [64]u8 = undefined;
    try generateRandomHexID(daemon.config.io, &id);

    var name_buf: [64]u8 = undefined;
    const name = if (params.name) |n| try normalizeName(n) else try generateRandomName(daemon.config.io, &name_buf);
    if (daemon.containers.contains(name)) return CrateError.ContainerNameInUse;

    const ctr = try Container.create(daemon.allocator, daemon.config.io);
    errdefer ctr.destroy(daemon.allocator);
    const a = ctr.allocator();

    var merged = mergeConfig(image.config, params.config);
    merged.env = try mergeEnv(a, image.config.env, params.config.env);

    const now = std.Io.Clock.now(.real, daemon.config.io).toNanoseconds();
    ctr.id = id;
    ctr.id_short = id[0..12].*;
    ctr.name = try a.dupe(u8, name);
    ctr.created_at = @intCast(now);
    ctr.config = try clone.config(a, merged);
    ctr.host_config = try clone.hostConfig(a, params.host_config);
    ctr.image_id = try a.dupe(u8, image.id);
    ctr.image_name = try a.dupe(u8, params.config.image);
    ctr.rw_layer_id = try a.dupe(u8, &id);

    try daemon.images.createWritableLayer(&id, image);
    try ctr.persistState(&daemon.config);
    try daemon.containers.add(ctr);

    daemon.events.publish(.{
        .event_type = .container,
        .action = "create",
        .actor_id = &id,
        .attrs = &.{ .{ .key = "name", .value = name }, .{ .key = "image", .value = params.config.image } },
        .time_nano = now,
    });

    return .{ .id = id, .warnings = &.{} };
}

fn generateRandomHexID(io: std.Io, out: *[64]u8) !void {
    var bytes: [32]u8 = undefined;
    try io.randomSecure(&bytes);
    out.* = std.fmt.bytesToHex(bytes, .lower);
}

fn generateRandomName(io: std.Io, buf: *[64]u8) ![]u8 {
    var bytes: [4]u8 = undefined;
    try io.randomSecure(&bytes);
    const n = std.mem.readInt(u32, &bytes, .little);
    return std.fmt.bufPrint(buf, "container_{d}", .{n}) catch unreachable;
}

/// Docker accepts names with or without a leading '/', matching
/// `[a-zA-Z0-9][a-zA-Z0-9_.-]*`.
fn normalizeName(raw: []const u8) ![]const u8 {
    const name = if (raw.len > 0 and raw[0] == '/') raw[1..] else raw;
    if (name.len == 0 or name.len > 63 or !std.ascii.isAlphanumeric(name[0])) return CrateError.InvalidParameter;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '-') return CrateError.InvalidParameter;
    }
    return name;
}

fn mergeConfig(image_cfg: anytype, user_cfg: ContainerConfig) ContainerConfig {
    var out = user_cfg;
    if (user_cfg.cmd.len == 0 and user_cfg.entrypoint.len == 0) out.cmd = image_cfg.cmd;
    if (user_cfg.entrypoint.len == 0) out.entrypoint = image_cfg.entrypoint;
    if (user_cfg.working_dir.len == 0) out.working_dir = image_cfg.working_dir;
    if (user_cfg.user.len == 0) out.user = image_cfg.user;
    return out;
}

/// Image env first, with any key the user also sets dropped so the user wins.
fn mergeEnv(a: std.mem.Allocator, image_env: []const []const u8, user_env: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    outer: for (image_env) |ie| {
        const key = envKey(ie);
        for (user_env) |ue| if (std.mem.eql(u8, envKey(ue), key)) continue :outer;
        try out.append(a, ie);
    }
    try out.appendSlice(a, user_env);
    return out.toOwnedSlice(a);
}

fn envKey(kv: []const u8) []const u8 {
    return kv[0 .. std.mem.indexOfScalar(u8, kv, '=') orelse kv.len];
}

test "mergeEnv lets user override image env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const env = try mergeEnv(arena.allocator(), &.{ "PATH=/bin", "A=1" }, &.{"A=2"});
    try std.testing.expectEqual(@as(usize, 2), env.len);
    try std.testing.expectEqualStrings("PATH=/bin", env[0]);
    try std.testing.expectEqualStrings("A=2", env[1]);
}

test "normalizeName strips slash and rejects junk" {
    try std.testing.expectEqualStrings("web", try normalizeName("/web"));
    try std.testing.expectError(CrateError.InvalidParameter, normalizeName("bad name"));
    try std.testing.expectError(CrateError.InvalidParameter, normalizeName("-x"));
}
