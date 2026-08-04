const std = @import("std");

pub const PortMapping = struct {
    host_port: u16,
    container_port: u16,
    protocol: []const u8 = "tcp",
};

pub const PortMapper = struct {
    pub fn formatAddNatRule(
        allocator: std.mem.Allocator,
        mapping: PortMapping,
        container_ip: []const u8,
    ) ![]const u8 {
        return std.fmt.allocPrint(allocator, "iptables -t nat -A PREROUTING -p {s} --dport {d} -j DNAT --to-destination {s}:{d}", .{
            mapping.protocol,
            mapping.host_port,
            container_ip,
            mapping.container_port,
        });
    }

    pub fn formatDeleteNatRule(
        allocator: std.mem.Allocator,
        mapping: PortMapping,
        container_ip: []const u8,
    ) ![]const u8 {
        return std.fmt.allocPrint(allocator, "iptables -t nat -D PREROUTING -p {s} --dport {d} -j DNAT --to-destination {s}:{d}", .{
            mapping.protocol,
            mapping.host_port,
            container_ip,
            mapping.container_port,
        });
    }
};

test "port mapper iptables rule formatting" {
    const alloc = std.testing.allocator;

    const mapping = PortMapping{ .host_port = 8080, .container_port = 80 };
    const add_rule = try PortMapper.formatAddNatRule(alloc, mapping, "172.17.0.2");
    defer alloc.free(add_rule);

    try std.testing.expectEqualStrings("iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 172.17.0.2:80", add_rule);
}
