const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const remove_mod = @import("remove.zig");

pub const PruneReport = struct {
    containers_deleted: [][]const u8,
    space_reclaimed: u64,

    pub fn jsonStringify(self: PruneReport, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("ContainersDeleted");
        try jws.write(self.containers_deleted);
        try jws.objectField("SpaceReclaimed");
        try jws.write(self.space_reclaimed);
        try jws.endObject();
    }
};

pub fn containerPrune(daemon: *Daemon, allocator: std.mem.Allocator) !PruneReport {
    const list = try daemon.containers.list(allocator);
    defer allocator.free(list);

    var deleted = std.ArrayList([]const u8).empty;
    errdefer {
        for (deleted.items) |d| allocator.free(d);
        deleted.deinit(allocator);
    }

    for (list) |ctr| {
        ctr.lock();
        const is_running = ctr.state.running;
        ctr.unlock();

        if (!is_running) {
            const id_copy = try allocator.dupe(u8, ctr.id[0..]);
            try deleted.append(allocator, id_copy);

            remove_mod.containerRemove(daemon, ctr.id[0..], true, true) catch |err| {
                std.log.warn("Failed to remove container {s} during prune: {}", .{ ctr.id[0..12], err });
                if (deleted.pop()) |discarded| {
                    allocator.free(discarded);
                }
            };
        }
    }

    return PruneReport{
        .containers_deleted = try deleted.toOwnedSlice(allocator),
        .space_reclaimed = 0,
    };
}
