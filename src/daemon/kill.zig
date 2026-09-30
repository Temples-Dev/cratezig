const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const runc = @import("../runtime/runc.zig");

pub fn containerKill(daemon: *Daemon, name: []const u8, signal_opt: ?[]const u8) !void {
    const ctr = daemon.containers.get(name) orelse return error.ContainerNotFound;
    defer ctr.release();

    ctr.lock();
    const is_running = ctr.state.running;
    const signal = signal_opt orelse "SIGKILL";
    if (is_running) ctr.restart_suppressed = true;
    ctr.unlock();

    if (!is_running) {
        return error.ContainerNotRunning;
    }

    try runc.kill(daemon.config.io, ctr.id[0..], signal, daemon.allocator);

    const now = std.Io.Clock.now(.real, daemon.config.io).toNanoseconds();
    daemon.events.publish(.{
        .event_type = .container,
        .action = "kill",
        .actor_id = ctr.id[0..],
        .time_nano = now,
    });
}
