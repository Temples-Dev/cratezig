const std = @import("std");

pub const Network = struct {
    id: []const u8,
    name: []const u8,
    driver: []const u8,
    created: i64,
    internel: bool = false,
    enable_ipv6: bool = false,
    ipam: IPAMConfig,
};

pub const IPAMConfig = struct {
    driver: []const u8 = "default",
    configs: []IPAMPoolConfig = &.{},
};

pub const IPAMPoolConfig = struct {
    subnet: []const u8, // "172.17.0.0/16"
    gateway: []const u8, // "172.17.0.1"
    ip_range: []const u8 = "",
};
