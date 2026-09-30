const std = @import("std");
const linux = std.os.linux;
const Daemon = @import("daemon.zig").Daemon;
const Container = @import("../container/container.zig").Container;
const runc = @import("../runtime/runc.zig");
const start_mod = @import("start.zig");

/// Marks the daemon as child subreaper so container init processes are
/// re-parented to it once `runc create` exits. That lets the monitor
/// `waitpid` the real exit status. Call once at daemon startup.
pub fn becomeSubreaper() void {
    const rc = linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
    if (linux.errno(rc) != .SUCCESS) std.log.warn("PR_SET_CHILD_SUBREAPER failed; exit codes will be unreliable", .{});
}

/// Blocks until `pid` exits and returns a Docker-style exit code
/// (status, or 128+signal).
fn waitExit(daemon: *Daemon, ctr: *Container, pid: u32) i32 {
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(@intCast(pid), &status, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return pollUntilStopped(daemon, ctr),
        }
    }
    if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
    if (linux.W.IFSIGNALED(status)) return 128 + @as(i32, @intCast(@intFromEnum(linux.W.TERMSIG(status))));
    return 255;
}

/// Fallback when the process is not our child (subreaper unavailable): the
/// exit status is lost, so report 255 once runc says it stopped.
fn pollUntilStopped(daemon: *Daemon, ctr: *Container) i32 {
    const io = daemon.config.io;
    while (true) {
        const state = runc.getState(io, ctr.id[0..], daemon.allocator) catch return 255;
        defer state.deinit(daemon.allocator);
        if (std.mem.eql(u8, state.parsed.value.status, "stopped")) return 255;
        std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    }
}

pub fn watchContainer(daemon: *Daemon, ctr: *Container, pid: u32) void {
    const io = daemon.config.io;
    const exit_code = waitExit(daemon, ctr, pid);
    runc.delete(io, ctr.id[0..], daemon.allocator, true) catch {};

    const now = std.Io.Clock.now(.real, io).toNanoseconds();

    ctr.lock();
    ctr.state.running = false;
    ctr.state.paused = false;
    ctr.state.pid = 0;
    ctr.state.exit_code = exit_code;
    ctr.state.finished_at = @intCast(now);
    ctr.state.status = .exited;
    ctr.persistState(&daemon.config) catch |err| {
        std.log.err("failed to persist state for {s}: {}", .{ ctr.id[0..12], err });
    };

    daemon.images.unmountWritableLayer(ctr.rw_layer_id) catch |err| {
        std.log.warn("unmount failed for {s}: {}", .{ ctr.id[0..12], err });
    };

    const net_mode = start_mod.networkName(ctr.host_config.network_mode);
    if (start_mod.usesBridge(net_mode)) {
        if (ctr.network_settings.networks.fetchRemove(net_mode)) |kv| {
            daemon.network.releaseEndpoint(net_mode, ctr.id[0..], kv.value.ip_address) catch |err| {
                std.log.warn("release endpoint failed for {s}: {}", .{ ctr.id[0..12], err });
            };
        }
    }
    // A run longer than 10s counts as healthy and resets the backoff.
    if (now - ctr.state.started_at > 10 * std.time.ns_per_s) ctr.restart_count = 0;
    const should_restart = restartWanted(ctr);
    ctr.unlock();

    var code_buf: [12]u8 = undefined;
    const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{exit_code}) catch "";
    daemon.events.publish(.{
        .event_type = .container,
        .action = "die",
        .actor_id = ctr.id[0..],
        .attrs = &.{.{ .key = "exitCode", .value = code_str }},
        .time_nano = now,
    });

    if (should_restart) restart(daemon, ctr);
}

/// Caller holds the container lock.
fn restartWanted(ctr: *Container) bool {
    if (ctr.restart_suppressed) return false;
    const policy = ctr.host_config.restart_policy;
    return switch (policy.name) {
        .no => false,
        .on_failure => ctr.state.exit_code != 0,
        .always, .unless_stopped => true,
    };
}

fn restart(daemon: *Daemon, ctr: *Container) void {
    ctr.lock();
    const delay_ms = @min(@as(i64, 100) << @intCast(@min(ctr.restart_count, 10)), 60_000);
    ctr.restart_count += 1;
    ctr.state.restarting = true;
    ctr.state.status = .restarting;
    ctr.unlock();
    std.Io.sleep(daemon.config.io, .fromMilliseconds(delay_ms), .awake) catch {};

    // A stop/kill/rm may have arrived during the backoff.
    ctr.lock();
    const suppressed = ctr.restart_suppressed or ctr.state.status == .removing;
    ctr.state.restarting = false;
    if (suppressed) ctr.state.status = .exited;
    ctr.unlock();
    if (suppressed) return;

    start_mod.containerStart(daemon, ctr.id[0..]) catch |err| {
        std.log.err("restart failed for {s}: {}", .{ ctr.id[0..12], err });
    };
}
