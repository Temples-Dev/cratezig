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

    registry_mirrors: []const []const u8 = &.{},

    // Path helpers
    //
    pub fn init(io: std.Io) DaemonConfig {
        return .{ .io = io };
    }

    /// {data_root}/containers/
    pub fn containersDir(self: *const DaemonConfig, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "{s}/containers", .{self.data_root}) catch unreachable;
    }

    /// {data_root}/containers/{id}
    pub fn containerDir(self: *const DaemonConfig, id: []const u8, buf: []u8) []u8 {
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
            if (err == openError.FileNotFound) return self.*;
            return err;
        };

        defer file.close(self.io);

        var read_buf: [4096]u8 = undefined;
        var file_reader = file.reader(self.io, &read_buf);
        const content = try file_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(content);

        const JsonConfig = struct {
            data_root: []const u8 = "/var/lib/docker",
            storage_driver: []const u8 = "overlay2",
            default_bridge: bool = true,
            bridge_ip: []const u8 = "172.17.0.1/16",
            ip_forward: bool = true,
            ip_tables: bool = true,
            userland_proxy: bool = true,
            dns: []const []const u8 = &.{},
            log_driver: []const u8 = "json-file",
            selinux_runtime: bool = false,
            default_runtime: []const u8 = "runc",
            runc_path: []const u8 = "/usr/bin/runc",
            shutdown_timeout: u32 = 15,
            insecure_registries: []const []const u8 = &.{},
            registry_mirrors: []const []const u8 = &.{},
        };

        const parsed = try std.json.parseFromSlice(JsonConfig, allocator, content, .{ .ignore_unknown_fields = true });
        // We do not call parsed.deinit() so that string fields allocated within the parsed JSON remain valid.

        return DaemonConfig{
            .io = self.io,
            .data_root = parsed.value.data_root,
            .storage_driver = parsed.value.storage_driver,
            .default_bridge = parsed.value.default_bridge,
            .bridge_ip = parsed.value.bridge_ip,
            .ip_forward = parsed.value.ip_forward,
            .ip_tables = parsed.value.ip_tables,
            .userland_proxy = parsed.value.userland_proxy,
            .dns = parsed.value.dns,
            .log_driver = parsed.value.log_driver,
            .selinux_runtime = parsed.value.selinux_runtime,
            .default_runtime = parsed.value.default_runtime,
            .runc_path = parsed.value.runc_path,
            .shutdown_timeout = parsed.value.shutdown_timeout,
            .insecure_registries = parsed.value.insecure_registries,
            .registry_mirrors = parsed.value.registry_mirrors,
        };
    }
};
