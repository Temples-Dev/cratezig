const std = @import("std");
const DaemonConfig = @import("../config/config.zig").DaemonConfig;
const Network = @import("types.zig").Network;
const IPAMConfig = @import("types.zig").IPAMConfig;
const IPAMPoolConfig = @import("types.zig").IPAMPoolConfig;
const EndpointSettings = @import("../container/container.zig").EndpointSettings;

const bridge = @import("bridge.zig");
const IPAM = @import("ipam.zig").IPAM;

pub const LoadError = error{
    InvalidJson,
    MissingId,
};

pub const Endpoint = struct {
    id: []const u8,
    settings: EndpointSettings,
};

pub const NetworkController = struct {
    allocator: std.mem.Allocator,
    config: DaemonConfig,
    by_id: std.StringHashMap(*Network),
    by_name: std.StringHashMap([]const u8),
    ipam_pools: std.StringHashMap(*IPAM),
    lock: std.Io.RwLock = .init,

    pub fn init(allocator: std.mem.Allocator, config: DaemonConfig) !NetworkController {
        var ctrl = NetworkController{
            .allocator = allocator,
            .config = config,
            .by_id = std.StringHashMap(*Network).init(allocator),
            .by_name = std.StringHashMap([]const u8).init(allocator),
            .ipam_pools = std.StringHashMap(*IPAM).init(allocator),
        };
        try ctrl.loadFromDisk();
        return ctrl;
    }

    pub fn deinit(self: *NetworkController) void {
        var it = self.ipam_pools.valueIterator();
        while (it.next()) |ipam_ptr| {
            ipam_ptr.*.deinit();
            self.allocator.destroy(ipam_ptr.*);
        }
        self.ipam_pools.deinit();
        self.by_id.deinit();
        self.by_name.deinit();
    }

    /// Ensures the default bridge network exists. Called once at startup after init.
    pub fn setup(self: *NetworkController) !void {
        if (self.by_name.contains("bridge")) return;

        const id = try generateId(self.config.io, self.allocator);

        const pools = try self.allocator.alloc(IPAMPoolConfig, 1);
        pools[0] = .{
            .subnet = "172.17.0.0/16",
            .gateway = "172.17.0.1",
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

        // Run bridge setup and initialize IPAM
        try bridge.setupBridge(self.config.io);
        const ipam_inst = try self.allocator.create(IPAM);
        ipam_inst.* = try IPAM.init(self.allocator, "172.17.0.0/16", "172.17.0.1");
        try self.ipam_pools.put(net.id, ipam_inst);

        std.log.info("initialized default bridge network {s}", .{net.id});
    }

    pub fn get(self: *NetworkController, id_or_name: []const u8) ?*Network {
        self.lock.lockSharedUncancelable(self.config.io);
        defer self.lock.unlockShared(self.config.io);

        if (self.by_id.get(id_or_name)) |net| return net;
        if (self.by_name.get(id_or_name)) |id| return self.by_id.get(id);
        return null;
    }

    pub fn list(self: *NetworkController, allocator: std.mem.Allocator) ![]*Network {
        self.lock.lockSharedUncancelable(self.config.io);
        defer self.lock.unlockShared(self.config.io);

        var result = try std.ArrayList(*Network).initCapacity(allocator, self.by_id.count());
        var it = self.by_id.valueIterator();
        while (it.next()) |net| result.appendAssumeCapacity(net.*);
        return try result.toOwnedSlice(allocator);
    }

    pub fn createEndpoint(self: *NetworkController, net_name: []const u8, container_id: []const u8, pid: u32) !Endpoint {
        self.lock.lockUncancelable(self.config.io);
        defer self.lock.unlock(self.config.io);

        const net = self.get(net_name) orelse return error.NetworkNotFound;
        const ipam = self.ipam_pools.get(net.id) orelse return error.NetworkHasNoIPAMPool;

        const ip = try ipam.allocate();
        errdefer ipam.release(ip);

        try bridge.connectContainer(self.config.io, container_id, pid, ip);

        const ep_id = try generateId(self.config.io, self.allocator);

        return Endpoint{
            .id = ep_id,
            .settings = .{
                .network_id = net.id,
                .endpoint_id = ep_id,
                .gateway = "172.17.0.1",
                .ip_address = ip,
                .ip_prefix_len = 16,
            },
        };
    }

    pub fn releaseEndpoint(self: *NetworkController, net_name: []const u8, container_id: []const u8, ip: []const u8) !void {
        self.lock.lockUncancelable(self.config.io);
        defer self.lock.unlock(self.config.io);

        const net = self.get(net_name) orelse return error.NetworkNotFound;
        if (self.ipam_pools.get(net.id)) |ipam| {
            ipam.release(ip);
        }
        try bridge.disconnectContainer(self.config.io, container_id);
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
        var file_reader = file.reader(self.config.io, &read_buf);
        const content = try file_reader.interface.allocRemaining(self.allocator, std.Io.Limit.limited(1 * 1024 * 1024));
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

fn generateId(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [32]u8 = undefined;
    try io.randomSecure(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return try allocator.dupe(u8, &hex);
}

