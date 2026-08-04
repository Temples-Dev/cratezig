const std = @import("std");

pub const VethPair = struct {
    host_ifname: []const u8,
    container_ifname: []const u8,

    pub fn formatCreateCmd(allocator: std.mem.Allocator, host_if: []const u8, container_if: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "ip link add {s} type veth peer name {s}", .{ host_if, container_if });
    }

    pub fn formatMoveNetnsCmd(allocator: std.mem.Allocator, container_if: []const u8, pid: u32) ![]const u8 {
        return std.fmt.allocPrint(allocator, "ip link set {s} netns {d}", .{ container_if, pid });
    }
};

test "veth command formatting" {
    const alloc = std.testing.allocator;

    const create_cmd = try VethPair.formatCreateCmd(alloc, "veth0_host", "veth0_ctr");
    defer alloc.free(create_cmd);
    try std.testing.expectEqualStrings("ip link add veth0_host type veth peer name veth0_ctr", create_cmd);

    const move_cmd = try VethPair.formatMoveNetnsCmd(alloc, "veth0_ctr", 1234);
    defer alloc.free(move_cmd);
    try std.testing.expectEqualStrings("ip link set veth0_ctr netns 1234", move_cmd);
}
