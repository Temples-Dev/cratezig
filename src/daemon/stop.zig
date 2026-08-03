const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const runc = @import("../runtime/runc.zig");
const CrateError = @import("../errdefs/errors.zig").Error;

pub fn containerStop(daemon: *Daemon, name: []const u8, timeout_secs: ?u32) !void {
    const ctr = daemon.containers.get(name) orelse return CrateError.ContainerNotFound;

    ctr.lock();
    if (!ctr.state.running) {
        ctr.unlock();
        return;
    }

    const stop_signal = ctr.config.stop_signal;
    const timeout = timeout_secs orelse ctr.config.stop_timeout;
    ctr.unlock();

    try runc.kill(daemon.config.io, ctr.id[0..], stop_signal, daemon.allocator);

    const now_ts = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds();

    daemon.events.publish(
        .{
            .event_type = .container,
            .action = "kill",
            .actor_id = ctr.id[0..],
            .actor_attrs = std.StringHashMap([]const u8).init(daemon.allocator),
            .time_nano = now_ts,
        }
    );

    // 2. Wait for the container to exit (the monitor thread will do the cleanup)
    const deadline_ns = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds() + @as(i128, timeout) * std.time.ns_per_s;
    while (std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds() < deadline_ns) {
        if (!ctr.isRunning()) break;
        try std.Io.sleep(daemon.config.io, std.Io.Duration.fromMilliseconds(50), .awake); // poll every 50ms
    }

    // 3. Force kill if it didn't stop in time
    if (ctr.isRunning()) {
        try runc.kill(daemon.config.io, ctr.id[0..], "SIGKILL", daemon.allocator);
        // Wait a bit more for the monitor thread to pick this up
        try std.Io.sleep(daemon.config.io, std.Io.Duration.fromSeconds(2), .awake);
    }

    const stop_ts = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds();

    daemon.events.publish(.{
        .event_type = .container,
        .action = "stop",
        .actor_id = ctr.id[0..],
        .actor_attrs = std.StringHashMap([]const u8).init(daemon.allocator),
        .time_nano = stop_ts,
    });
}

