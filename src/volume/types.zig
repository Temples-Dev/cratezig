const std = @import("std");

pub const Volume = struct {
    name: []const u8,
    driver: []const u8 = "local",
    mountpoint: []const u8, // absolute host path to volume data
    created: i64,
    labels: std.StringHashMap([]const u8),
    options: std.StringHashMap([]const u8),
    scope: []const u8 = "local",
};
