const std = @import("std");

pub const Network = struct {
    id: []const u8,
    name: []const u8,
    driver: []const u8,
    created: i64,
    internel: bool = false,
    enable_ipv6: bool = false,
    ipam: IPAMConfig,

    pub fn jsonStringify(self: Network, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Id");
        try jws.write(self.id);
        try jws.objectField("Name");
        try jws.write(self.name);
        try jws.objectField("Driver");
        try jws.write(self.driver);
        try jws.objectField("Created");
        try jws.write(self.created);
        try jws.objectField("Internal");
        try jws.write(self.internel);
        try jws.objectField("EnableIPv6");
        try jws.write(self.enable_ipv6);
        try jws.objectField("IPAM");
        try jws.beginObject();
        try jws.objectField("Driver");
        try jws.write(self.ipam.driver);
        try jws.objectField("Config");
        try jws.beginArray();
        for (self.ipam.configs) |c| {
            try jws.beginObject();
            try jws.objectField("Subnet");
            try jws.write(c.subnet);
            try jws.objectField("Gateway");
            try jws.write(c.gateway);
            try jws.endObject();
        }
        try jws.endArray();
        try jws.endObject();
        try jws.endObject();
    }
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
