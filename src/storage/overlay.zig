const std = @import("std");

pub const OverlayPaths = struct {
    lowerdirs: []const []const u8,
    upperdir: []const u8,
    workdir: []const u8,
    merged: []const u8,
};

pub const OverlayDriver = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OverlayDriver {
        return .{ .allocator = allocator };
    }

    pub fn buildMountOptions(self: OverlayDriver, paths: OverlayPaths) ![]const u8 {
        var lower_joined = std.ArrayList(u8).empty;
        defer lower_joined.deinit(self.allocator);

        for (paths.lowerdirs, 0..) |ld, idx| {
            if (idx > 0) try lower_joined.append(self.allocator, ':');
            try lower_joined.appendSlice(self.allocator, ld);
        }

        return std.fmt.allocPrint(self.allocator, "lowerdir={s},upperdir={s},workdir={s}", .{
            lower_joined.items,
            paths.upperdir,
            paths.workdir,
        });
    }
};

test "overlay driver options" {
    const alloc = std.testing.allocator;
    const driver = OverlayDriver.init(alloc);

    const l1 = "/var/lib/cratezig/layers/layer1";
    const l2 = "/var/lib/cratezig/layers/layer2";
    const lower = [_][]const u8{ l1, l2 };

    const opts = try driver.buildMountOptions(.{
        .lowerdirs = &lower,
        .upperdir = "/tmp/container1/upper",
        .workdir = "/tmp/container1/work",
        .merged = "/tmp/container1/merged",
    });
    defer alloc.free(opts);

    try std.testing.expectEqualStrings("lowerdir=/var/lib/cratezig/layers/layer1:/var/lib/cratezig/layers/layer2,upperdir=/tmp/container1/upper,workdir=/tmp/container1/work", opts);
}
