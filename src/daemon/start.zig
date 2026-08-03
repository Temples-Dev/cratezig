const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const monitor = @import("monitor.zig");
const ocispec = @import("oci_spec.zig");
const runc = @import("../runtime/runc.zig");
const CrateError = @import("../errdefs/errors.zig").Error;

pub fn containerStart(daemon: *Daemon, name: []const u8) !void {
    const ctr = daemon.containers.get(name) orelse return CrateError.ContainerNotFound;

    ctr.lock();
    const state = ctr.state;
    ctr.unlock();

    if (state.paused) return CrateError.ContainerAlreadyRunning;
    if (state.running) return CrateError.ContainerAlreadyRunning;
    if (state.status == .removing) return CrateError.ContainerBeingRemoved;

    ctr.lock();
    defer ctr.unlock();

    try daemon.images.mountWritableLayer(ctr.rw_layer_id);
    var rootfs_buf: [512]u8 = undefined;
    ctr.rootfs_paths = try std.fmt.bufPrint(&rootfs_buf, "{s}/overlay2/{s}/merged", .{ daemon.config.data_root, ctr.rw_layer_id });

    var spec_buf: [64 * 1024]u8 = undefined;
    const spec_json = try ocispec.generate(ctr, &spec_buf, daemon);

    var bundle_buf: [512]u8 = undefined;
    const bundle_dir = try std.fmt.bufPrint(&bundle_buf, "/run/runc/{s}", .{ctr.id[0..]});

    std.Io.Dir.createDirAbsolute(daemon.config.io, bundle_dir, .default_dir) catch |err| {
        if (err != std.Io.Dir.CreateDirPathError.PathAlreadyExists) return err;
    };

    var spec_path_buf: [512]u8 = undefined;
    const spec_path = try std.fmt.bufPrint(&spec_path_buf, "{s}/config.json", .{bundle_dir});

    const spec_file = try std.Io.Dir.createFileAbsolute(daemon.config.io, spec_path, .{});
    defer spec_file.close(daemon.config.io);

    try spec_file.writePositionalAll(daemon.config.io, spec_json, 0);

    try runc.create(daemon.config.io, ctr.id[0..], bundle_dir, daemon.allocator);

    const runc_state = try runc.getState(daemon.config.io, ctr.id[0..], daemon.allocator);
    defer runc_state.deinit(daemon.allocator);
    const pid = runc_state.parsed.value.pid;

    const net_mode = ctr.host_config.network_mode;
    if (!std.mem.eql(u8, net_mode, "host") and !std.mem.eql(u8, net_mode, "none")) {
        const endpoint = try daemon.network.createEndpoint(net_mode, ctr.id[0..], pid);
        try ctr.network_settings.networks.put(net_mode, endpoint.settings);
    }

    _ = try runc.start(daemon.config.io, ctr.id[0..], daemon.allocator);

    const now = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds();
    ctr.state = .{ .status = .running, .running = true, .pid = @intCast(pid), .started_at = @intCast(now), .exit_code = 0 };

    try ctr.persistState(&daemon.config);

    const thread = try std.Thread.spawn(.{}, monitor.watchContainer, .{ daemon, ctr });
    thread.detach();

    daemon.events.publish(.{
        .event_type = .container,
        .action = "start",
        .actor_id = ctr.id[0..],
        .actor_attrs = std.StringHashMap([]const u8).init(daemon.allocator),
        .time_nano = now,
    });
}
