const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;

pub const ContainerStats = struct {
    read: []const u8,
    pids_stats: PidsStats,
    memory_stats: MemoryStats,
    cpu_stats: CpuStats,

    pub const PidsStats = struct {
        current: u64 = 0,
    };

    pub const MemoryStats = struct {
        usage: u64 = 0,
        limit: u64 = 0,
    };

    pub const CpuStats = struct {
        cpu_usage: CpuUsage,
        system_cpu_usage: u64 = 0,

        pub const CpuUsage = struct {
            total_usage: u64 = 0,
        };
    };

    pub fn jsonStringify(self: ContainerStats, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("read");
        try jws.write(self.read);
        
        try jws.objectField("pids_stats");
        try jws.beginObject();
        try jws.objectField("current");
        try jws.write(self.pids_stats.current);
        try jws.endObject();

        try jws.objectField("memory_stats");
        try jws.beginObject();
        try jws.objectField("usage");
        try jws.write(self.memory_stats.usage);
        try jws.objectField("limit");
        try jws.write(self.memory_stats.limit);
        try jws.endObject();

        try jws.objectField("cpu_stats");
        try jws.beginObject();
        try jws.objectField("cpu_usage");
        try jws.beginObject();
        try jws.objectField("total_usage");
        try jws.write(self.cpu_stats.cpu_usage.total_usage);
        try jws.endObject();
        try jws.objectField("system_cpu_usage");
        try jws.write(self.cpu_stats.system_cpu_usage);
        try jws.endObject();

        try jws.endObject();
    }
};

pub fn containerStats(daemon: *Daemon, name: []const u8, allocator: std.mem.Allocator) !ContainerStats {
    const ctr = daemon.containers.get(name) orelse return error.ContainerNotFound;

    ctr.lock();
    const is_running = ctr.state.running;
    ctr.unlock();

    if (!is_running) {
        return error.ContainerNotRunning;
    }

    var time_buf: [64]u8 = undefined;
    const now_ts = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds();
    const read_time = try std.fmt.bufPrint(&time_buf, "{d}", .{now_ts});

    return ContainerStats{
        .read = try allocator.dupe(u8, read_time),
        .pids_stats = .{ .current = 1 },
        .memory_stats = .{ .usage = 1024 * 1024 * 5, .limit = 1024 * 1024 * 1024 * 4 },
        .cpu_stats = .{
            .cpu_usage = .{ .total_usage = 1000000 },
            .system_cpu_usage = 100000000,
        },
    };
}
