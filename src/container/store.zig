const std = @import("std");

const container_mod = @import("container.zig");
const Container = container_mod.Container;
const ContainerState = container_mod.ContainerState;
const ContainerConfig = container_mod.ContainerConfig;
const HostConfig = container_mod.HostConfig;
const PortBinding = container_mod.PortBinding;
const RestartPolicy = container_mod.RestartPolicy;
const DaemonConfig = @import("../config/config.zig").DaemonConfig;

pub const ContainerStore = struct {
    io: std.Io,

    allocator: std.mem.Allocator,

    lock: std.Io.RwLock = .init,

    by_id: std.StringHashMap(*Container),
    by_name: std.StringHashMap([]const u8),
    sorted_ids: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ContainerStore {
        return .{
            .io = io,
            .allocator = allocator,
            .by_id = std.StringHashMap(*Container).init(allocator),
            .by_name = std.StringHashMap([]const u8).init(allocator),
            .sorted_ids = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *ContainerStore) void {
        var it = self.by_id.valueIterator();
        while (it.next()) |ctr| ctr.*.release();
        self.sorted_ids.deinit(self.allocator);
        self.by_id.deinit();
        self.by_name.deinit();
    }

    pub fn add(self: *ContainerStore, ctr: *Container) !void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        const id = ctr.id[0..];
        if (self.by_name.contains(ctr.name)) return error.ContainerNameInUse;
        try self.by_id.put(id, ctr);
        try self.by_name.put(ctr.name, id);

        var idx: usize = 0;
        while (idx < self.sorted_ids.items.len) : (idx += 1) {
            if (std.mem.order(u8, id, self.sorted_ids.items[idx]) == .lt) break;
        }
        try self.sorted_ids.insert(self.allocator, idx, id);
    }

    /// Looks up by full id, name, or unique id prefix. The result is retained;
    /// the caller must `release()` it.
    pub fn get(self: *ContainerStore, id_or_prefix: []const u8) ?*Container {
        self.lock.lockSharedUncancelable(self.io);
        defer self.lock.unlockShared(self.io);
        const ctr = self.find(id_or_prefix) orelse return null;
        return ctr.retain();
    }

    pub fn contains(self: *ContainerStore, id_or_prefix: []const u8) bool {
        self.lock.lockSharedUncancelable(self.io);
        defer self.lock.unlockShared(self.io);
        return self.find(id_or_prefix) != null;
    }

    fn find(self: *ContainerStore, id_or_prefix: []const u8) ?*Container {
        if (self.by_id.get(id_or_prefix)) |ctr| return ctr;
        if (self.by_name.get(id_or_prefix)) |id| return self.by_id.get(id);

        if (id_or_prefix.len == 0 or self.sorted_ids.items.len == 0) return null;

        var low: usize = 0;
        var high: usize = self.sorted_ids.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (std.mem.order(u8, self.sorted_ids.items[mid], id_or_prefix) == .lt) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        if (low < self.sorted_ids.items.len and std.mem.startsWith(u8, self.sorted_ids.items[low], id_or_prefix)) {
            if (low + 1 < self.sorted_ids.items.len and std.mem.startsWith(u8, self.sorted_ids.items[low + 1], id_or_prefix)) {
                return null;
            }
            return self.by_id.get(self.sorted_ids.items[low]);
        }

        return null;
    }

    /// Unregisters the container and drops the store's reference.
    pub fn delete(self: *ContainerStore, id: []const u8) void {
        const removed = blk: {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            const entry = self.by_id.fetchRemove(id) orelse break :blk null;
            _ = self.by_name.remove(entry.value.name);
            for (self.sorted_ids.items, 0..) |s_id, idx| {
                if (std.mem.eql(u8, s_id, id)) {
                    _ = self.sorted_ids.orderedRemove(idx);
                    break;
                }
            }
            break :blk entry.value;
        };
        if (removed) |ctr| ctr.release();
    }

    pub fn list(self: *ContainerStore, allocator: std.mem.Allocator) ![]*Container {
        self.lock.lockSharedUncancelable(self.io);
        defer self.lock.unlockShared(self.io);

        var result = try std.ArrayList(*Container).initCapacity(allocator, self.by_id.count());

        var it = self.by_id.valueIterator();
        while (it.next()) |ctr| result.appendAssumeCapacity(ctr.*.retain());
        return try result.toOwnedSlice(allocator);
    }

    /// Releases every container returned by `list` and frees the slice.
    pub fn releaseList(allocator: std.mem.Allocator, items: []*Container) void {
        for (items) |ctr| ctr.release();
        allocator.free(items);
    }

    pub fn loadFromDisk(self: *ContainerStore, data_root: []const u8, allocator: std.mem.Allocator) !void {
        var path_buf: [512]u8 = undefined;
        const containers_dir = try std.fmt.bufPrint(&path_buf, "{s}/containers", .{data_root});

        var dir = std.Io.Dir.openDir(.cwd(), self.io, containers_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound or err == error.AccessDenied) return;
            return err;
        };

        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;

            var config_path_buf: [512]u8 = undefined;
            const config_path = try std.fmt.bufPrint(&config_path_buf, "{s}/containers/{s}/config.v2.json", .{ data_root, entry.name });

            const ctr = loadContainerFromFile(self.io, config_path, allocator) catch |err| {
                std.log.warn("failed to load container {s}: {}", .{ entry.name, err });
                continue;
            };

            // No live-restore yet: a container recorded as running lost its
            // monitor when the previous daemon exited, so report it exited.
            if (ctr.state.running or ctr.state.paused) {
                ctr.state = .{ .status = .exited, .exit_code = 255, .finished_at = ctr.state.finished_at };
            }
            self.add(ctr) catch |err| {
                std.log.warn("skipping container {s}: {}", .{ entry.name, err });
                ctr.destroy(allocator);
            };
        }
    }
};

pub const LoadError = error{
    InvalidJson,
    MissingId,
    MissingName,
};

fn jsonString(val: ?std.json.Value) ?[]const u8 {
    const v = val orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(val: ?std.json.Value) ?i64 {
    const v = val orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

fn jsonBool(val: ?std.json.Value) ?bool {
    const v = val orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn loadContainerFromFile(io: std.Io, path: []const u8, allocator: std.mem.Allocator) !*Container {
    const file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const content = try file_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return LoadError.InvalidJson,
    };

    const ctr = try Container.create(allocator, io);
    errdefer ctr.destroy(allocator);
    const a = ctr.allocator();

    // ID
    const id_str = jsonString(root.get("ID") orelse root.get("Id")) orelse return LoadError.MissingId;
    @memset(&ctr.id, 0);
    const id_copy_len = @min(id_str.len, 64);
    @memcpy(ctr.id[0..id_copy_len], id_str[0..id_copy_len]);
    @memset(&ctr.id_short, 0);
    const short_len = @min(id_str.len, 12);
    @memcpy(ctr.id_short[0..short_len], ctr.id[0..short_len]);

    // Name
    const name_str = jsonString(root.get("Name")) orelse return LoadError.MissingName;
    ctr.name = try a.dupe(u8, name_str);

    ctr.created_at = jsonInt(root.get("Created")) orelse 0;

    ctr.image_id = try a.dupe(u8, jsonString(root.get("Image")) orelse "");
    ctr.image_name = try a.dupe(u8, jsonString(root.get("ImageName")) orelse "");

    ctr.rw_layer_id = try a.dupe(u8, jsonString(root.get("RwLayerID")) orelse "");
    ctr.rootfs_paths = try a.dupe(u8, jsonString(root.get("RootfsPath")) orelse "");

    ctr.log_path = try a.dupe(u8, jsonString(root.get("LogPath")) orelse "");
    ctr.log_driver = if (jsonString(root.get("LogDriver"))) |v| try a.dupe(u8, v) else "json-file";

    ctr.state = parseState(root.get("State"));

    ctr.config = try parseConfig(root.get("Config"), a);
    try parseHostConfig(root.get("HostConfig"), a, &ctr.host_config);

    return ctr;
}

fn parseState(val: ?std.json.Value) ContainerState {
    var state = ContainerState{ .exit_code = 0 };

    const obj = switch (val orelse return state) {
        .object => |o| o,
        else => return state,
    };

    if (jsonString(obj.get("Status"))) |s| {
        state.status = std.meta.stringToEnum(ContainerState.Status, s) orelse .exited;
    }
    if (jsonBool(obj.get("Running"))) |v| state.running = v;
    if (jsonBool(obj.get("Paused"))) |v| state.paused = v;
    if (jsonBool(obj.get("Restarting"))) |v| state.restarting = v;
    if (jsonBool(obj.get("OOMKilled"))) |v| state.oom_killed = v;
    if (jsonBool(obj.get("Dead"))) |v| state.dead = v;
    if (jsonInt(obj.get("Pid"))) |v| state.pid = @intCast(v);
    if (jsonInt(obj.get("ExitCode"))) |v| state.exit_code = @intCast(v);
    if (jsonInt(obj.get("StartedAt"))) |v| state.started_at = v;
    if (jsonInt(obj.get("FinishedAt"))) |v| state.finished_at = v;

    return state;
}

fn parseConfig(val: ?std.json.Value, allocator: std.mem.Allocator) !ContainerConfig {
    var cfg = ContainerConfig{
        .image = "",
        .labels = std.StringHashMap([]const u8).init(allocator),
    };

    const obj = switch (val orelse return cfg) {
        .object => |o| o,
        else => return cfg,
    };

    if (jsonString(obj.get("Image"))) |v| cfg.image = try allocator.dupe(u8, v);
    if (jsonString(obj.get("WorkingDir"))) |v| cfg.working_dir = try allocator.dupe(u8, v);
    if (jsonString(obj.get("User"))) |v| cfg.user = try allocator.dupe(u8, v);
    if (jsonBool(obj.get("Tty"))) |v| cfg.tty = v;
    if (jsonBool(obj.get("OpenStdin"))) |v| cfg.open_stdin = v;
    if (jsonString(obj.get("StopSignal"))) |v| cfg.stop_signal = try allocator.dupe(u8, v);
    if (jsonInt(obj.get("StopTimeout"))) |v| cfg.stop_timeout = @intCast(v);

    if (obj.get("Cmd")) |v| cfg.cmd = try parseStringArray(v, allocator);
    if (obj.get("Entrypoint")) |v| cfg.entrypoint = try parseStringArray(v, allocator);
    if (obj.get("Env")) |v| cfg.env = try parseStringArray(v, allocator);

    if (obj.get("Labels")) |labels_val| {
        if (labels_val == .object) {
            var label_it = labels_val.object.iterator();
            while (label_it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const lval = try allocator.dupe(u8, jsonString(entry.value_ptr.*) orelse "");
                try cfg.labels.put(key, lval);
            }
        }
    }

    return cfg;
}

fn parseHostConfig(val: ?std.json.Value, a: std.mem.Allocator, hc: *HostConfig) !void {
    const obj = switch (val orelse return) {
        .object => |o| o,
        else => return,
    };
    if (jsonInt(obj.get("Memory"))) |v| hc.memory = v;
    if (jsonInt(obj.get("MemorySwap"))) |v| hc.memory_swap = v;
    if (jsonInt(obj.get("CpuShares"))) |v| hc.cpu_shares = v;
    if (jsonInt(obj.get("CpuQuota"))) |v| hc.cpu_quota = v;
    if (jsonInt(obj.get("CpuPeriod"))) |v| hc.cpu_period = v;
    if (jsonInt(obj.get("PidsLimit") orelse obj.get("PidLimits"))) |v| hc.pid_limits = v;
    if (jsonInt(obj.get("ShmSize"))) |v| hc.shm_size = v;
    if (jsonBool(obj.get("Privileged"))) |v| hc.privleged = v;
    if (jsonBool(obj.get("ReadonlyRootfs"))) |v| hc.read_only_rootfs = v;
    if (jsonBool(obj.get("Init"))) |v| hc.init = v;
    if (jsonString(obj.get("NetworkMode"))) |v| hc.network_mode = try a.dupe(u8, v);
    if (jsonString(obj.get("IpcMode"))) |v| hc.ipc_mode = try a.dupe(u8, v);
    if (jsonString(obj.get("PidMode"))) |v| hc.pid_mode = try a.dupe(u8, v);
    if (obj.get("Binds")) |v| hc.binds = try parseStringArray(v, a);
    if (obj.get("Mounts")) |v| hc.mounts = try parseStringArray(v, a);
    if (obj.get("Dns")) |v| hc.dns = try parseStringArray(v, a);
    if (obj.get("ExtraHosts")) |v| hc.extra_hosts = try parseStringArray(v, a);
    if (obj.get("CapAdd")) |v| hc.cap_add = try parseStringArray(v, a);
    if (obj.get("CapDrop")) |v| hc.cap_drop = try parseStringArray(v, a);

    if (obj.get("RestartPolicy")) |rp| if (rp == .object) {
        if (jsonString(rp.object.get("Name"))) |n| hc.restart_policy.name = RestartPolicy.parseName(n);
        if (jsonInt(rp.object.get("MaximumRetryCount"))) |n| hc.restart_policy.maximum_retry_count = @intCast(n);
    };

    if (obj.get("PortBindings")) |pb| if (pb == .object) {
        var it = pb.object.iterator();
        while (it.next()) |e| {
            const arr = switch (e.value_ptr.*) {
                .array => |x| x,
                else => continue,
            };
            const out = try a.alloc(PortBinding, arr.items.len);
            for (arr.items, 0..) |item, i| {
                out[i] = .{ .host_port = "" };
                const o = if (item == .object) item.object else continue;
                out[i] = .{
                    .host_ip = try a.dupe(u8, jsonString(o.get("HostIp")) orelse "0.0.0.0"),
                    .host_port = try a.dupe(u8, jsonString(o.get("HostPort")) orelse ""),
                };
            }
            try hc.port_bindings.put(try a.dupe(u8, e.key_ptr.*), out);
        }
    };
}

fn parseStringArray(val: std.json.Value, allocator: std.mem.Allocator) ![]const []const u8 {
    const arr = switch (val) {
        .array => |a| a,
        else => return &.{},
    };
    const result = try allocator.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        result[i] = try allocator.dupe(u8, jsonString(item) orelse "");
    }
    return result;
}

test "container persistence roundtrip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var tmp_buf: [512]u8 = undefined;
    const tmp_path = tmp_buf[0..try tmp.dir.realPath(std.testing.io, &tmp_buf)];

    const test_io = testing.io;
    const cfg: DaemonConfig = .{ .data_root = tmp_path, .io = test_io };

    const ctr = try Container.create(alloc, test_io);
    defer ctr.destroy(alloc);
    const a = ctr.allocator();

    const id_str = "a1b2c3d4e5f67890123456789012345678901234567890123456789012345678";
    @memcpy(ctr.id[0..], id_str);
    @memcpy(ctr.id_short[0..], id_str[0..12]);
    ctr.name = try a.dupe(u8, "test-container");
    ctr.created_at = 123456789;
    ctr.image_id = try a.dupe(u8, "sha256:abc123456789");
    ctr.image_name = try a.dupe(u8, "alpine:latest");
    ctr.state = .{ .status = .created, .running = false };
    ctr.config.image = "alpine:latest";

    try ctr.persistState(&cfg);

    var file_path_buf: [512]u8 = undefined;
    const config_file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/containers/{s}/config.v2.json", .{ tmp_path, id_str });

    const loaded = try loadContainerFromFile(test_io, config_file_path, alloc);
    defer loaded.destroy(alloc);

    try testing.expectEqualStrings("test-container", loaded.name);
    try testing.expectEqualStrings(id_str[0..12], loaded.id_short[0..12]);
    try testing.expectEqual(123456789, loaded.created_at);
    try testing.expectEqualStrings("alpine:latest", loaded.config.image);
}

test "container outlives store deletion while a caller holds it" {
    const alloc = std.testing.allocator;
    var store = ContainerStore.init(alloc, std.testing.io);
    defer store.deinit();

    const ctr = try Container.create(alloc, std.testing.io);
    ctr.id = @splat('a');
    ctr.name = try ctr.allocator().dupe(u8, "web");
    try store.add(ctr);

    const held = store.get("web").?;
    store.delete(held.id[0..]);
    try std.testing.expect(store.get("web") == null);
    // Still valid: the store dropped its ref, ours keeps it alive.
    try std.testing.expectEqualStrings("web", held.name);
    held.release(); // frees; the testing allocator flags any leak
}
