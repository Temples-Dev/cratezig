const std = @import("std");
const DaemonConfig = @import("../config/config.zig").DaemonConfig;
const Network = @import("types.zig").Network;
const IPAMConfig = @import("types.zig").IPAMConfig;
const IPAMPoolConfig = @import("types.zig").IPAMPoolConfig;

pub const LoadError = error{
    InvalidJson,
    MissingId,
};

pub const NetworkController = struct {
    allocator: std.mem.Allocator,
    config: DaemonConfig,
    by_id: std.StringHashMap(*Network),
    by_name: std.StringHashMap([]const u8),
    lock: std.Io.RwLock = .{},

    pub fn init(allocator: std.mem.Allocator, config: DaemonConfig) !NetworkController {
        var ctrl = NetworkController{
            .allocator = allocator,
            .config = config,
            .by_id = std.StringHashMap(*Network).init(allocator),
            .by_name = std.StringHashMap([]const u8).init(allocator),
        };
        try ctrl.loadFromDisk();
        return ctrl;
    }

    pub fn deinit(self: *NetworkController) void {
        self.by_id.deinit();
        self.by_name.deinit();
    }

    /// Ensures the default bridge network exists. Called once at startup after init.
    pub fn setup(self: *NetworkController) !void {
        if (self.by_name.contains("bridge")) return;

        const id = try generateId(self.allocator);

        const pools = try self.allocator.alloc(IPAMPoolConfig, 1);
        pools[0] = .{
            .subnet = self.config.bridge_ip,
            .gateway = self.config.bridge_ip,
        };

        const net = try self.allocator.create(Network);
        net.* = .{
            .id = id,
            .name = "bridge",
            .driver = "bridge",
            .created = 0,
            .ipam = .{ .configs = pools },
        };

        try self.by_id.put(net.id, net);
        try self.by_name.put(net.name, net.id);

        std.log.info("initialized default bridge network {s}", .{net.id});
    }

    pub fn get(self: *NetworkController, id_or_name: []const u8) ?*Network {
        self.lock.lockShared(self.config.io);
        defer self.lock.unlockShared(self.config.io);

        if (self.by_id.get(id_or_name)) |net| return net;
        if (self.by_name.get(id_or_name)) |id| return self.by_id.get(id);
        return null;
    }

    pub fn list(self: *NetworkController, allocator: std.mem.Allocator) ![]*Network {
        self.lock.lockShared(self.config.io);
        defer self.lock.unlockShared(self.config.io);

        var result = try std.ArrayList(*Network).initCapacity(allocator, self.by_id.count());
        var it = self.by_id.valueIterator();
        while (it.next()) |net| result.appendAssumeCapacity(net.*);
        return try result.toOwnedSlice();
    }

    fn loadFromDisk(self: *NetworkController) !void {
        var path_buf: [512]u8 = undefined;
        const net_dir = try std.fmt.bufPrint(&path_buf, "{s}/network/files", .{self.config.data_root});

        var dir = std.Io.Dir.openDirAbsolute(self.config.io, net_dir, .{ .iterate = true }) catch |err| {
            if (err == std.Io.Dir.OpenError.FileNotFound) return;
            return err;
        };
        defer dir.close(self.config.io);

        var it = dir.iterate();
        while (try it.next(self.config.io)) |entry| {
            if (entry.kind != .file) continue;

            var net_path_buf: [512]u8 = undefined;
            const net_path = try std.fmt.bufPrint(&net_path_buf, "{s}/network/files/{s}", .{ self.config.data_root, entry.name });

            const net = self.loadNetworkFromFile(net_path) catch |err| {
                std.log.warn("failed to load network {s}: {}", .{ entry.name, err });
                continue;
            };

            try self.by_id.put(net.id, net);
            try self.by_name.put(net.name, net.id);
        }
    }

    fn loadNetworkFromFile(self: *NetworkController, path: []const u8) !*Network {
        const file = try std.Io.Dir.openFileAbsolute(self.config.io, path, .{});
        defer file.close(self.config.io);

        var read_buf: [4096]u8 = undefined;
        const content = try file.reader(self.config.io, &read_buf).readAllAlloc(self.allocator, 1 * 1024 * 1024);
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return LoadError.InvalidJson,
        };

        const net = try self.allocator.create(Network);
        errdefer self.allocator.destroy(net);

        net.id = try self.allocator.dupe(u8, (root.get("Id") orelse return LoadError.MissingId).string);
        net.name = try self.allocator.dupe(u8, if (root.get("Name")) |v| v.string else "");
        net.driver = try self.allocator.dupe(u8, if (root.get("Driver")) |v| v.string else "bridge");
        net.created = if (root.get("Created")) |v| v.integer else 0;
        net.internel = if (root.get("Internal")) |v| v.bool else false;
        net.enable_ipv6 = if (root.get("EnableIPv6")) |v| v.bool else false;
        net.ipam = .{};

        return net;
    }
};

fn generateId(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const id = try allocator.alloc(u8, 64);
    _ = std.fmt.bufPrint(id, "{}", .{std.fmt.fmtSliceHexLower(&bytes)}) catch unreachable;
    return id;
}
