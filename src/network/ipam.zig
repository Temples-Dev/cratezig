const std = @import("std");

pub const IPAM = struct {
    allocator: std.mem.Allocator,
    subnet: []const u8,
    gateway: []const u8,
    allocated: std.StringHashMap(void),
    base: u32,
    host_bits: u6,

    pub fn init(allocator: std.mem.Allocator, subnet: []const u8, gateway: []const u8) !IPAM {
        var self = IPAM{
            .allocator = allocator,
            .subnet = subnet,
            .gateway = gateway,
            .allocated = std.StringHashMap(void).init(allocator),
            .base = 0,
            .host_bits = 0,
        };
        // Parse "172.17.0.0/16"
        const slash = std.mem.indexOf(u8, subnet, "/") orelse return error.InvalidParameter;
        const ip_str = subnet[0..slash];
        const prefix_len = try std.fmt.parseInt(u6, subnet[slash + 1..], 10);
        self.host_bits = 32 - prefix_len;
        self.base = parseIPv4(ip_str) orelse return error.InvalidParameter;

        // Pre-reserve the gateway
        const gw_owned = try allocator.dupe(u8, gateway);
        try self.allocated.put(gw_owned, {});

        return self;
    }

    pub fn deinit(self: *IPAM) void {
        var it = self.allocated.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.allocated.deinit();
    }

    /// Allocate the next available IP. Returns it as a string.
    pub fn allocate(self: *IPAM) ![]const u8 {
        const count: u32 = @as(u32, 1) << @intCast(self.host_bits);
        var i: u32 = 1; // skip .0 (network address)
        while (i < count - 1) : (i += 1) {
            const ip_int = self.base | i;
            var buf: [16]u8 = undefined;
            const ip_str = formatIPv4(ip_int, &buf);

            // Check if gateway or already allocated
            if (std.mem.eql(u8, ip_str, self.gateway)) continue;

            if (!self.allocated.contains(ip_str)) {
                const owned = try self.allocator.dupe(u8, ip_str);
                try self.allocated.put(owned, {});
                return owned;
            }
        }
        return error.SubnetExhausted;
    }

    /// Release an IP back to the pool.
    pub fn release(self: *IPAM, ip: []const u8) void {
        if (std.mem.eql(u8, ip, self.gateway)) return;
        if (self.allocated.fetchRemove(ip)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    fn parseIPv4(s: []const u8) ?u32 {
        var parts = std.mem.splitScalar(u8, s, '.');
        var result: u32 = 0;
        for (0..4) |_| {
            const p = parts.next() orelse return null;
            const b = std.fmt.parseInt(u8, p, 10) catch return null;
            result = (result << 8) | b;
        }
        return result;
    }

    fn formatIPv4(ip: u32, buf: *[16]u8) []u8 {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
            (ip >> 24) & 0xff,
            (ip >> 16) & 0xff,
            (ip >> 8) & 0xff,
            ip & 0xff,
        }) catch unreachable;
    }
};
