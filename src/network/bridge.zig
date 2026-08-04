const std = @import("std");

pub const BridgeConfig = struct {
    name: []const u8,
    subnet: []const u8 = "172.18.0.0/16",
    gateway: []const u8 = "172.18.0.1",
};

pub const BridgeManager = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BridgeManager {
        return .{ .allocator = allocator };
    }

    pub fn formatCreateBridgeCommand(self: BridgeManager, config: BridgeConfig) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "ip link add name {s} type bridge && ip addr add {s} dev {s} && ip link set dev {s} up", .{
            config.name,
            config.gateway,
            config.name,
            config.name,
        });
    }

    pub fn formatDeleteBridgeCommand(self: BridgeManager, bridge_name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "ip link set dev {s} down && ip link delete {s} type bridge", .{
            bridge_name,
            bridge_name,
        });
    }
};

test "bridge manager command formatting" {
    const alloc = std.testing.allocator;
    const bm = BridgeManager.init(alloc);

    const cmd = try bm.formatCreateBridgeCommand(.{
        .name = "cz-br0",
        .subnet = "172.19.0.0/16",
        .gateway = "172.19.0.1/16",
    });
    defer alloc.free(cmd);

    try std.testing.expect(std.mem.indexOf(u8, cmd, "ip link add name cz-br0 type bridge") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "ip addr add 172.19.0.1/16 dev cz-br0") != null);

    const del_cmd = try bm.formatDeleteBridgeCommand("cz-br0");
    defer alloc.free(del_cmd);
    try std.testing.expectEqualStrings("ip link set dev cz-br0 down && ip link delete cz-br0 type bridge", del_cmd);
}
