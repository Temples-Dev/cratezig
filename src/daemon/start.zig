const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const Container = @import("../container/container.zig").Container;
const monitor = @import("monitor.zig");
const ocispec = @import("oci_spec.zig");
const runc = @import("../runtime/runc.zig");
const CrateError = @import("../errdefs/errors.zig").Error;
const fsutil = @import("../util/fsutil.zig");

/// Docker clients send "default" for the default bridge.
pub fn networkName(mode: []const u8) []const u8 {
    return if (std.mem.eql(u8, mode, "default")) "bridge" else mode;
}

pub fn usesBridge(mode: []const u8) bool {
    return !std.mem.eql(u8, mode, "host") and !std.mem.eql(u8, mode, "none");
}

pub fn containerStart(daemon: *Daemon, name: []const u8) !void {
    const ctr = daemon.containers.get(name) orelse return CrateError.ContainerNotFound;

    // Hold the lock for the whole transition so concurrent starts cannot race.
    ctr.lock();
    defer ctr.unlock();

    if (ctr.state.running or ctr.state.paused) return CrateError.ContainerAlreadyRunning;
    if (ctr.state.status == .removing) return CrateError.ContainerBeingRemoved;
    ctr.restart_suppressed = false;

    const io = daemon.config.io;
    const id = ctr.id[0..];

    try daemon.images.mountWritableLayer(ctr.rw_layer_id);
    errdefer daemon.images.unmountWritableLayer(ctr.rw_layer_id) catch {};
    ctr.rootfs_paths = try std.fmt.allocPrint(ctr.allocator(), "{s}/overlay2/{s}/merged", .{ daemon.config.data_root, ctr.rw_layer_id });

    var bundle_buf: [256]u8 = undefined;
    const bundle_dir = try daemon.config.bundleDir(id, &bundle_buf);
    try std.Io.Dir.createDirPath(.cwd(), io, bundle_dir);
    try writeSpec(daemon, ctr, bundle_dir);

    const output = try openOutputLog(daemon, ctr);
    defer output.close(io);

    // Clear any stale runc record left by a previous daemon run.
    runc.delete(io, id, daemon.allocator, true) catch {};
    try runc.create(io, id, bundle_dir, output);
    errdefer runc.delete(io, id, daemon.allocator, true) catch {};

    const runc_state = try runc.getState(io, id, daemon.allocator);
    defer runc_state.deinit(daemon.allocator);
    const pid = runc_state.parsed.value.pid;

    const net_mode = networkName(ctr.host_config.network_mode);
    if (usesBridge(net_mode)) {
        const endpoint = try daemon.network.createEndpoint(net_mode, id, pid);
        try ctr.network_settings.networks.put(net_mode, endpoint.settings);
    }

    try runc.start(io, id, daemon.allocator);

    const now = std.Io.Clock.now(.real, io).toNanoseconds();
    ctr.state = .{ .status = .running, .running = true, .pid = pid, .started_at = @intCast(now), .exit_code = 0 };
    try ctr.persistState(&daemon.config);

    const thread = try std.Thread.spawn(.{}, monitor.watchContainer, .{ daemon, ctr, pid });
    thread.detach();

    daemon.events.publish(.{ .event_type = .container, .action = "start", .actor_id = id, .time_nano = now });
}

fn writeSpec(daemon: *Daemon, ctr: *Container, bundle_dir: []const u8) !void {
    const spec_buf = try daemon.allocator.alloc(u8, 64 * 1024);
    defer daemon.allocator.free(spec_buf);
    const spec_json = try ocispec.generate(ctr, daemon.config.io, daemon.allocator, spec_buf);

    var spec_path_buf: [320]u8 = undefined;
    const spec_path = try std.fmt.bufPrint(&spec_path_buf, "{s}/config.json", .{bundle_dir});
    const spec_file = try std.Io.Dir.createFileAbsolute(daemon.config.io, spec_path, .{});
    defer spec_file.close(daemon.config.io);
    try spec_file.writePositionalAll(daemon.config.io, spec_json, 0);
}

/// Raw container stdout/stderr, appended across restarts. Replaced by a
/// json-file logging shim in Phase 3.
fn openOutputLog(daemon: *Daemon, ctr: *Container) !std.Io.File {
    var path_buf: [512]u8 = undefined;
    return fsutil.openAppend(try outputLogPath(daemon, ctr, &path_buf));
}

pub fn outputLogPath(daemon: *Daemon, ctr: *const Container, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/containers/{s}/output.log", .{ daemon.config.data_root, ctr.id[0..] });
}
