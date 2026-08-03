const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const Container = @import("../container/container.zig").Container;
const runc = @import("../runtime/runc.zig");

pub fn watchContainer(daemon: *Daemon, ctr: *Container) void {
    const exit_code = runc.wait(daemon.config.io, ctr.id[0..], daemon.allocator) catch 137; // 137 = SIGKILL

    const now = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds();

    // Update container state
    ctr.lock();
    ctr.state.running = false;
    ctr.state.pid = 0;
    ctr.state.exit_code = @intCast(exit_code);
    ctr.state.finished_at = @intCast(now);
    ctr.state.status = .exited;
    ctr.unlock();

    ctr.persistState(&daemon.config) catch |err| {
        std.log.err("failed to persist state for {s}: {}", .{ ctr.id[0..12], err });
    };

    // Unmount the overlay filesystem
    daemon.images.unmountWritableLayer(ctr.rw_layer_id) catch |err| {
        std.log.warn("unmount failed for {s}: {}", .{ ctr.id[0..12], err });
    };

    const net_mode = ctr.host_config.network_mode;
    if (!std.mem.eql(u8, net_mode, "host") and !std.mem.eql(u8, net_mode, "none")) {
        if (ctr.network_settings.networks.get(net_mode)) |settings| {
            daemon.network.releaseEndpoint(net_mode, ctr.id[0..], settings.ip_address) catch |err| {
                std.log.warn("release endpoint failed for {s}: {}", .{ ctr.id[0..12], err });
            };
        }
    }

    daemon.events.publish(.{
        .event_type = .container,
        .action = "die",
        .actor_id = ctr.id[0..],
        .actor_attrs = std.StringHashMap([]const u8).init(daemon.allocator),
        .time_nano = now,
    });

    handleRestartPolicy(daemon, ctr);
}

fn handleRestartPolicy(daemon: *Daemon, ctr: *Container) void {
    const policy = ctr.host_config.restart_policy;

    switch (policy.name) {
        .no => return,
        .on_failure => if (ctr.state.exit_code == 0) return,
        .always, .unless_stopped => {},
    }

    const backoff_ms: u64 = 100;
    std.Io.sleep(ctr.io, std.Io.Duration.fromMilliseconds(backoff_ms), .awake) catch {};

    ctr.lock();
    ctr.state.status = .restarting;
    ctr.state.restarting = true;
    ctr.unlock();

    @import("start.zig").containerStart(daemon, ctr.id[0..]) catch |err| {
        std.log.err("restart failed for {s}: {}", .{ctr.id[0..12], err});
    };
}
