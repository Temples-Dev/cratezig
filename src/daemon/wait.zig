const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;

pub fn containerWait(daemon: *Daemon, name: []const u8) !i32 {
    const ctr = daemon.containers.get(name) orelse return error.ContainerNotFound;

    while (true) {
        ctr.lock();
        const is_running = ctr.state.running;
        const exit_code = ctr.state.exit_code;
        ctr.unlock();

        if (!is_running) {
            return exit_code;
        }

        std.Io.sleep(daemon.config.io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
    }
}
