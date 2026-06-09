const std = @import("std");

const openError = std.Io.File.OpenError;

pub const DaemonConfig = struct {

    // IO instance

    io: std.Io,

    // Storage

    /// Where all Docker data lives. Default: /var/lib/docker
    data_root: []const u8 = "/var/lib/docker",

    storage_driver: []const u8 = "overlay2",

    // Networking
    default_bridge: bool = true,

    bridge_ip: []const u8 = "172.17.0.1/16",

    ip_forward: bool = true,

    ip_tables: bool = true,

    userland_proxy: bool = true,

    dns: []const []const u8 = &.{},

    //  Logging
    log_driver: []const u8 = "json-file",

    // Security
    selinux_runtime: bool = false,

    // Runtime
    default_runtime: []const u8 = "runc",

    /// Path to runc binary
    runc_path: []const u8 = "/usr/bin/runc",

    shutdown_timeout: u32 = 15,

    // Registry
    insecure_registries: []const []const u8 = &.{},

    registry_mirrors: []const []const u8,

    // Path helpers
    //
    pub fn init(io: std.Io) DaemonConfig {
        return .{ .io = io };
    }

    /// {data_root}/containers/
    pub fn containersDir(self: *const DaemonConfig, buf: []u8) u8 {
        return std.fmt.bufPrint(buf, "{s}/containers", .{self.data_root}) catch unreachable;
    }

    /// {data_root}/containers/{id}
    pub fn containerDir(self: *const DaemonConfig, id: []const u8, buf: []u8) u8 {
        return std.fmt.bufPrint(buf, "{s}/containers/{s}", .{ self.data_root, id }) catch unreachable;
    }

    /// {data_root}/overlay2
    pub fn overlay2Dir(self: *const DaemonConfig, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "{s}/overlay2", .{self.data_root}) catch unreachable;
    }

    /// {data}/volumes/
    pub fn volumesDir(self: *const DaemonConfig, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "{s}/volumes", .{self.data_root}) catch unreachable;
    }

    /// {data_root}/network/files
    pub fn networkDir(self: *const DaemonConfig, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "{s}/network/files", .{self.data_root}) catch unreachable;
    }

    /// Load config from JSON file. Returns defaults if file doesn't exist
    pub fn loadConfig(self: *const DaemonConfig, allocator: std.mem.Allocator, path: []const u8) !DaemonConfig {
        const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch |err| {
            if (err == openError.FileNotFound) return DaemonConfig{};
            return err;
        };

        defer file.close(self.io);

        const content = try file.reader(self.io, 1024 * 1024); // something is wrong here: I am not using aallocator yet freeing one

        defer allocator.free(content); // be back: and fix this.

        const parsed = try std.json.parseFromSlice(DaemonConfig, allocator, content, .{ .ignore_unknown_fields = true });

        defer parsed.deinit();

        return parsed.value;
    }
};
