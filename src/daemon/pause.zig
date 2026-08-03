const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const runc = @import("../runtime/runc.zig");

pub fn containerPause(daemon: *Daemon, name: []const u8) !void {
    const ctr = daemon.containers.get(name) orelse return error.ContainerNotFound;

    ctr.lock();
    const is_running = ctr.state.running;
    const is_paused = ctr.state.paused;
    ctr.unlock();

    if (!is_running) return error.ContainerNotRunning;
    if (is_paused) return error.ContainerAlreadyPaused;

    try runc.pause(daemon.config.io, ctr.id[0..], daemon.allocator);

    ctr.lock();
    ctr.state.paused = true;
    ctr.state.status = .paused;
    try ctr.persistState(&daemon.config);
    ctr.unlock();

    const now = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds();
    daemon.events.publish(.{
        .event_type = .container,
        .action = "pause",
        .actor_id = ctr.id[0..],
        .actor_attrs = std.StringHashMap([]const u8).init(daemon.allocator),
        .time_nano = now,
    });
}

pub fn containerUnpause(daemon: *Daemon, name: []const u8) !void {
    const ctr = daemon.containers.get(name) orelse return error.ContainerNotFound;

    ctr.lock();
    const is_running = ctr.state.running;
    const is_paused = ctr.state.paused;
    ctr.unlock();

    if (!is_running) return error.ContainerNotRunning;
    if (!is_paused) return error.ContainerNotPaused;

    try runc.unpause(daemon.config.io, ctr.id[0..], daemon.allocator);

    ctr.lock();
    ctr.state.paused = false;
    ctr.state.status = .running;
    try ctr.persistState(&daemon.config);
    ctr.unlock();

    const now = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds();
    daemon.events.publish(.{
        .event_type = .container,
        .action = "unpause",
        .actor_id = ctr.id[0..],
        .actor_attrs = std.StringHashMap([]const u8).init(daemon.allocator),
        .time_nano = now,
    });
}
