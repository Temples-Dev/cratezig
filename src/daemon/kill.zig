const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const runc = @import("../runtime/runc.zig");

pub fn containerKill(daemon: *Daemon, name: []const u8, signal_opt: ?[]const u8) !void {
    const ctr = daemon.containers.get(name) orelse return error.ContainerNotFound;

    ctr.lock();
    const is_running = ctr.state.running;
    const signal = signal_opt orelse "SIGKILL";
    ctr.unlock();

    if (!is_running) {
        return error.ContainerNotRunning;
    }

    try runc.kill(daemon.config.io, ctr.id[0..], signal, daemon.allocator);

    const now = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds();
    daemon.events.publish(.{
        .event_type = .container,
        .action = "kill",
        .actor_id = ctr.id[0..],
        .actor_attrs = std.StringHashMap([]const u8).init(daemon.allocator),
        .time_nano = now,
    });
}
