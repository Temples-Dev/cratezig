const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const CrateError = @import("../errdefs/errors.zig").Error;

pub fn containerRemove(daemon: *Daemon, name: []const u8, force: bool, remove_vols: bool) !void {
    _ = remove_vols;
    const ctr = daemon.containers.get(name) orelse return CrateError.ContainerNotFound;

    ctr.lock();
    const is_running = ctr.state.running;
    ctr.unlock();

    if (is_running) {
        if (force) {
            try @import("stop.zig").containerStop(daemon, name, 1);
        } else {
            return CrateError.ContainerAlreadyRunning;
        }
    }

    ctr.lock();
    ctr.state.status = .removing;
    try ctr.persistState(&daemon.config);
    ctr.unlock();

    // 1. Unmount overlay filesystem if mounted
    daemon.images.unmountWritableLayer(ctr.rw_layer_id) catch {};

    // 2. Delete directories
    var path_buf: [512]u8 = undefined;
    const container_dir = daemon.config.containerDir(&ctr.id, &path_buf);
    std.Io.Dir.cwd().deleteTree(daemon.config.io, container_dir) catch {};

    var overlay_buf: [512]u8 = undefined;
    const overlay_dir = try std.fmt.bufPrint(&overlay_buf, "{s}/overlay2/{s}", .{ daemon.config.data_root, ctr.rw_layer_id });
    std.Io.Dir.cwd().deleteTree(daemon.config.io, overlay_dir) catch {};

    // 3. Delete from store
    daemon.containers.delete(ctr.id[0..]);

    // 4. Publish event
    const now = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds();
    daemon.events.publish(.{
        .event_type = .container,
        .action = "destroy",
        .actor_id = ctr.id[0..],
        .actor_attrs = std.StringHashMap([]const u8).init(daemon.allocator),
        .time_nano = now,
    });
}
