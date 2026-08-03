const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const stop_mod = @import("stop.zig");
const start_mod = @import("start.zig");

pub fn containerRestart(daemon: *Daemon, name: []const u8, timeout_secs: ?u32) !void {
    const ctr = daemon.containers.get(name) orelse return error.ContainerNotFound;

    ctr.lock();
    const is_running = ctr.state.running;
    ctr.unlock();

    if (is_running) {
        try stop_mod.containerStop(daemon, name, timeout_secs);
    }

    try start_mod.containerStart(daemon, name);
}
