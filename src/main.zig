const std = @import("std");
const Config = @import("config/config.zig");
const Daemon = @import("daemon/daemon.zig").Daemon;
const Server = @import("server/server.zig").Server;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const default_cfg = Config.DaemonConfig.init(io);
    const cfg = try default_cfg.loadConfig(alloc, "/etc/docker/daemon.json");

    var daemon = try Daemon.init(alloc, cfg);
    defer daemon.deinit();

    std.log.info("Docker daemon started (data-root: {s})", .{cfg.data_root});

    const socket_path: []const u8 = "/var/run/docker.sock";

    var server = Server.init(&daemon, socket_path, alloc);
    server.listen() catch |err| {
        if (err == error.AccessDenied or err == error.PermissionDenied or err == error.AddressInUse) {
            std.log.info("System socket in use or restricted. Falling back to /tmp/cratezig.sock...", .{});
            server.socket_path = "/tmp/cratezig.sock";
            try server.listen();
        } else {
            return err;
        }
    };
}
