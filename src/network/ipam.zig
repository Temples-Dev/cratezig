const std = @import("std");

pub const IPAM = struct {
    allocator: std.mem.Allocator,
    subnet: []const u8,
    gateway: []const u8,
    bitmap: []u8,
    base: u32,
    host_bits: u6,
    cursor: u32,
    used: u32,

    pub fn init(allocator: std.mem.Allocator, subnet: []const u8, gateway: []const u8) !IPAM {
        const slash = std.mem.indexOf(u8, subnet, "/") orelse return error.InvalidParameter;
        const ip_str = subnet[0..slash];
        const prefix_len = try std.fmt.parseInt(u6, subnet[slash + 1 ..], 10);
        const host_bits: u6 = 32 - prefix_len;
        const host_count: u32 = @as(u32, 1) << @as(u5, @intCast(host_bits));

        const bitmap_bytes = (host_count + 7) / 8;
        const bitmap = try allocator.alloc(u8, bitmap_bytes);
        @memset(bitmap, 0);

        const base = parseIPv4(ip_str) orelse return error.InvalidParameter;

        var self = IPAM{
            .allocator = allocator,
            .subnet = subnet,
            .gateway = gateway,
            .bitmap = bitmap,
            .base = base,
            .host_bits = host_bits,
            .cursor = 1,
            .used = 0,
        };

        self.markUsed(0);
        self.markUsed(host_count - 1);

        const gw_host = parseIPv4(gateway) orelse return error.InvalidParameter;
        self.markUsed(gw_host - base);

        return self;
    }

    pub fn deinit(self: *IPAM) void {
        self.allocator.free(self.bitmap);
    }

    pub fn allocate(self: *IPAM) ![]const u8 {
        const host_count: u32 = @as(u32, 1) << @as(u5, @intCast(self.host_bits));
        const usable = host_count - 2;

        if (self.used >= usable) return error.SubnetExhausted;

        var tried: u32 = 0;
        while (tried < host_count) : (tried += 1) {
            const offset = self.cursor % host_count;
            self.cursor = offset + 1;

            if (offset == 0 or offset == host_count - 1) continue;
            if (self.isFree(offset)) {
                self.markUsed(offset);
                self.used += 1;
                const ip_int = self.base | offset;
                return try std.fmt.allocPrint(self.allocator, "{d}.{d}.{d}.{d}", .{
                    (ip_int >> 24) & 0xff,
                    (ip_int >> 16) & 0xff,
                    (ip_int >> 8) & 0xff,
                    ip_int & 0xff,
                });
            }
        }
        return error.SubnetExhausted;
    }

    pub fn release(self: *IPAM, ip: []const u8) void {
        if (std.mem.eql(u8, ip, self.gateway)) {
            self.allocator.free(ip);
            return;
        }
        if (parseIPv4(ip)) |ip_int| {
            const offset = ip_int - self.base;
            if (self.isUsed(offset)) {
                self.clearUsed(offset);
                if (self.used > 0) self.used -= 1;
            }
        }
        self.allocator.free(ip);
    }

    inline fn isFree(self: *const IPAM, offset: u32) bool {
        const byte = offset / 8;
        const bit: u8 = @as(u8, 1) << @intCast(offset % 8);
        return self.bitmap[byte] & bit == 0;
    }

    inline fn isUsed(self: *const IPAM, offset: u32) bool {
        return !self.isFree(offset);
    }

    inline fn markUsed(self: *IPAM, offset: u32) void {
        const byte = offset / 8;
        const bit: u8 = @as(u8, 1) << @intCast(offset % 8);
        self.bitmap[byte] |= bit;
    }

    inline fn clearUsed(self: *IPAM, offset: u32) void {
        const byte = offset / 8;
        const bit: u8 = @as(u8, 1) << @intCast(offset % 8);
        self.bitmap[byte] &= ~bit;
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
};
