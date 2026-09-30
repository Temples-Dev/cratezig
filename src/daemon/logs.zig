const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const outputLogPath = @import("start.zig").outputLogPath;

/// Returns the container's captured stdout/stderr (at most the last 10 MiB).
pub fn containerLogs(daemon: *Daemon, name: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const ctr = daemon.containers.get(name) orelse return error.ContainerNotFound;

    var path_buf: [512]u8 = undefined;
    const log_path = try outputLogPath(daemon, ctr, &path_buf);
    return std.Io.Dir.cwd().readFileAlloc(daemon.config.io, log_path, allocator, .limited(10 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => err,
    };
}
