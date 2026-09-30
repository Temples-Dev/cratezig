const std = @import("std");
const ju = @import("../util/jsonutil.zig");

pub const default_config_path = "/etc/cratezig/daemon.json";

pub const DaemonConfig = struct {
    io: std.Io,

    /// Where all persistent engine data lives. Never /var/lib/docker:
    /// sharing it with dockerd corrupts both engines' state.
    data_root: []const u8 = "/var/lib/cratezig",

    /// Runtime state (bundles, runc state, netns), like dockerd's exec-root.
    exec_root: []const u8 = "/run/cratezig",

    storage_driver: []const u8 = "overlay2",

    // Networking
    default_bridge: bool = true,
    bridge_ip: []const u8 = "172.17.0.1/16",
    ip_forward: bool = true,
    ip_tables: bool = true,
    userland_proxy: bool = true,
    dns: []const []const u8 = &.{},

    log_driver: []const u8 = "json-file",
    selinux_runtime: bool = false,

    default_runtime: []const u8 = "runc",
    /// runc binary; a bare name is resolved via PATH.
    runc_path: []const u8 = "runc",

    shutdown_timeout: u32 = 15,

    insecure_registries: []const []const u8 = &.{},
    registry_mirrors: []const []const u8 = &.{},

    pub fn init(io: std.Io) DaemonConfig {
        return .{ .io = io };
    }

    /// {data_root}/containers/{id}
    pub fn containerDir(self: *const DaemonConfig, id: []const u8, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "{s}/containers/{s}", .{ self.data_root, id }) catch unreachable;
    }

    /// {exec_root}/bundles/{id}
    pub fn bundleDir(self: *const DaemonConfig, id: []const u8, buf: []u8) ![]u8 {
        return std.fmt.bufPrint(buf, "{s}/bundles/{s}", .{ self.exec_root, id });
    }

    /// Loads `path` over the defaults. A missing file yields the defaults.
    /// Keys use dockerd's spelling ("data-root"); underscore spellings are
    /// also accepted. Strings are allocated with `allocator` and live for
    /// the rest of the process.
    pub fn loadConfig(self: *const DaemonConfig, allocator: std.mem.Allocator, path: []const u8) !DaemonConfig {
        const content = std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return self.*,
            else => return err,
        };
        defer allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();
        const obj = ju.object(parsed.value) orelse return error.InvalidConfig;

        var out = self.*;
        inline for (@typeInfo(DaemonConfig).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "io")) continue;
            const dashed = comptime dashName(f.name);
            if (obj.get(dashed) orelse obj.get(f.name)) |v| {
                @field(out, f.name) = switch (f.type) {
                    []const u8 => try allocator.dupe(u8, ju.str(v) orelse return error.InvalidConfig),
                    bool => ju.boolean(v) orelse return error.InvalidConfig,
                    u32 => std.math.cast(u32, ju.int(v) orelse return error.InvalidConfig) orelse return error.InvalidConfig,
                    []const []const u8 => try ju.strings(allocator, v),
                    else => @compileError("unsupported config field type"),
                };
            }
        }
        if (out.data_root.len == 0 or out.data_root[0] != '/') return error.InvalidConfig;
        if (out.exec_root.len == 0 or out.exec_root[0] != '/') return error.InvalidConfig;
        return out;
    }
};

fn dashName(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = undefined;
        for (name, 0..) |c, i| out[i] = if (c == '_') '-' else c;
        const final = out;
        return &final;
    }
}

test "loadConfig accepts dockerd spelling and rejects relative roots" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/daemon.json", .{root});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const defaults = DaemonConfig.init(io);

    const missing = try defaults.loadConfig(arena.allocator(), "/nonexistent/daemon.json");
    try std.testing.expectEqualStrings("/var/lib/cratezig", missing.data_root);

    try tmp.dir.writeFile(io, .{ .sub_path = "daemon.json", .data = "{\"data-root\":\"/srv/cz\",\"exec_root\":\"/run/x\",\"dns\":[\"1.1.1.1\"]}" });
    const cfg = try defaults.loadConfig(arena.allocator(), path);
    try std.testing.expectEqualStrings("/srv/cz", cfg.data_root);
    try std.testing.expectEqualStrings("/run/x", cfg.exec_root);
    try std.testing.expectEqualStrings("1.1.1.1", cfg.dns[0]);

    try tmp.dir.writeFile(io, .{ .sub_path = "daemon.json", .data = "{\"data-root\":\"rel\"}" });
    try std.testing.expectError(error.InvalidConfig, defaults.loadConfig(arena.allocator(), path));
}
