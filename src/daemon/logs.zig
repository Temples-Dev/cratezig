const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;

pub fn containerLogs(daemon: *Daemon, name: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const ctr = daemon.containers.get(name) orelse return error.ContainerNotFound;

    var path_buf: [512]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&path_buf, "{s}/containers/{s}/{s}-json.log", .{
        daemon.config.data_root,
        ctr.id[0..],
        ctr.id[0..],
    });

    const file = std.Io.Dir.openFileAbsolute(daemon.config.io, log_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return try allocator.dupe(u8, "");
        }
        return err;
    };
    defer file.close(daemon.config.io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(daemon.config.io, &read_buf);
    const content = try file_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    return content;
}
