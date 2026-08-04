const std = @import("std");

pub const MountSpec = struct {
    destination: []const u8,
    type: []const u8 = "bind",
    source: []const u8,
    options: []const []const u8,

    pub fn parseBindString(allocator: std.mem.Allocator, raw: []const u8) !MountSpec {
        var it = std.mem.splitScalar(u8, raw, ':');
        const src = it.next() orelse return error.InvalidBindMount;
        const dest = it.next() orelse return error.InvalidBindMount;
        const mode = it.next() orelse "rw";

        var opts = std.ArrayList([]const u8).empty;
        errdefer {
            for (opts.items) |o| allocator.free(o);
            opts.deinit(allocator);
        }

        try opts.append(allocator, try allocator.dupe(u8, "rbind"));
        if (std.mem.eql(u8, mode, "ro")) {
            try opts.append(allocator, try allocator.dupe(u8, "ro"));
        } else {
            try opts.append(allocator, try allocator.dupe(u8, "rw"));
        }

        return MountSpec{
            .destination = try allocator.dupe(u8, dest),
            .type = "bind",
            .source = try allocator.dupe(u8, src),
            .options = try opts.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *MountSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.destination);
        allocator.free(self.source);
        for (self.options) |o| allocator.free(o);
        allocator.free(self.options);
    }
};

test "parse bind mount string format" {
    const alloc = std.testing.allocator;

    var spec = try MountSpec.parseBindString(alloc, "/var/log/app:/app/logs:ro");
    defer spec.deinit(alloc);

    try std.testing.expectEqualStrings("/app/logs", spec.destination);
    try std.testing.expectEqualStrings("/var/log/app", spec.source);
    try std.testing.expectEqual(@as(usize, 2), spec.options.len);
    try std.testing.expectEqualStrings("rbind", spec.options[0]);
    try std.testing.expectEqualStrings("ro", spec.options[1]);
}
