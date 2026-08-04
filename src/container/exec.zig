const std = @import("std");
const ExecProcess = @import("container.zig").ExecProcess;

pub const ExecStore = struct {
    allocator: std.mem.Allocator,
    processes: std.StringHashMap(ExecProcess),

    pub fn init(allocator: std.mem.Allocator) ExecStore {
        return .{
            .allocator = allocator,
            .processes = std.StringHashMap(ExecProcess).init(allocator),
        };
    }

    pub fn deinit(self: *ExecStore) void {
        var it = self.processes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.value_ptr.container_id);
            for (entry.value_ptr.cmd) |c| self.allocator.free(c);
            self.allocator.free(entry.value_ptr.cmd);
        }
        self.processes.deinit();
    }

    pub fn createExec(
        self: *ExecStore,
        id: []const u8,
        container_id: []const u8,
        cmd: []const []const u8,
        tty: bool,
        privileged: bool,
    ) !void {
        var cmd_dupes = std.ArrayList([]const u8).empty;
        errdefer {
            for (cmd_dupes.items) |c| self.allocator.free(c);
            cmd_dupes.deinit(self.allocator);
        }

        for (cmd) |c| {
            try cmd_dupes.append(self.allocator, try self.allocator.dupe(u8, c));
        }

        const id_dupe = try self.allocator.dupe(u8, id);
        const ctr_dupe = try self.allocator.dupe(u8, container_id);

        const proc = ExecProcess{
            .id = id_dupe,
            .container_id = ctr_dupe,
            .cmd = try cmd_dupes.toOwnedSlice(self.allocator),
            .tty = tty,
            .privileged = privileged,
        };

        const key_dupe = try self.allocator.dupe(u8, id);
        try self.processes.put(key_dupe, proc);
    }
};

test "exec store registration and session management" {
    const alloc = std.testing.allocator;
    var store = ExecStore.init(alloc);
    defer store.deinit();

    const cmd = [_][]const u8{"/bin/sh", "-c", "ls -la"};
    try store.createExec("exec_123", "ctr_456", &cmd, true, false);

    const found = store.processes.get("exec_123");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("ctr_456", found.?.container_id);
    try std.testing.expect(found.?.tty);
}
