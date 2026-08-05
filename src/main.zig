const std = @import("std");
const Config = @import("config/config.zig");
const Daemon = @import("daemon/daemon.zig").Daemon;
const Server = @import("server/server.zig").Server;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len > 1) {
        const cmd = args[1];
        if (std.mem.eql(u8, cmd, "alias")) {
            std.debug.print(
                \\==================================================
                \\Cratezig Docker CLI Alias Opt-in Helper
                \\==================================================
                \\To use standard 'docker' CLI commands directly with Cratezig,
                \\add the following alias to your ~/.bashrc or ~/.zshrc:
                \\
                \\    alias docker='DOCKER_HOST=unix:///tmp/cratezig.sock docker'
                \\
                \\Or run commands natively via Cratezig CLI:
                \\
                \\    cratezig build -t api .
                \\==================================================
                \\
            , .{});
            return;
        } else if (!std.mem.eql(u8, cmd, "daemon")) {
            // Forward CLI commands (e.g. cratezig build -t api .) directly to Docker CLI with DOCKER_HOST pre-configured
            var child_args = try alloc.alloc([]const u8, args.len);
            defer alloc.free(child_args);
            child_args[0] = "docker";
            for (args[1..], 1..) |a, i| {
                child_args[i] = a;
            }

            try init.environ_map.put("DOCKER_HOST", "unix:///tmp/cratezig.sock");

            var child = try std.process.spawn(io, .{
                .argv = child_args,
                .environ_map = init.environ_map,
            });
            _ = try child.wait(io);
            return;
        }
    }

    // Run Cratezig Daemon
    const default_cfg = Config.DaemonConfig.init(io);
    const cfg = default_cfg.loadConfig(alloc, "/etc/cratezig/daemon.json") catch default_cfg;

    var daemon = try Daemon.init(alloc, cfg);
    defer daemon.deinit();

    var active_socket: []const u8 = "/var/run/cratezig.sock";
    var server = Server.init(&daemon, active_socket, alloc);

    server.listen() catch |err| {
        if (err == error.AccessDenied or err == error.PermissionDenied or err == error.AddressInUse) {
            active_socket = "/tmp/cratezig.sock";
            server.socket_path = active_socket;
            try server.listen();
        } else {
            return err;
        }
    };

    std.log.info("Cratezig daemon started (data-root: {s}, socket: {s})", .{ cfg.data_root, active_socket });
}
