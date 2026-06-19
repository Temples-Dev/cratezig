const std = @import("std");

const container_mod = @import("container.zig");
const Container = container_mod.Container;
const ContainerState = container_mod.ContainerState;
const ContainerConfig = container_mod.ContainerConfig;
const EndpointSettings = container_mod.EndpointSettings;
const PortBinding = container_mod.PortBinding;
const ExecProcess = container_mod.ExecProcess;

const openError = std.Io.Dir.OpenError;

pub const ContainerStore = struct {
    io: std.Io,

    allocator: std.mem.Allocator,

    lock: std.Io.RwLock = .{},

    by_id: std.StringHashMap(*Container),

    by_name: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ContainerStore {
        return .{
            .io = io,
            .allocator = allocator,
            .by_id = std.StringHashMap(*Container).init(allocator),
            .by_name = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ContainerStore) void {
        self.by_id.deinit();
        self.by_name.deinit();
    }

    pub fn add(self: *ContainerStore, ctr: *Container) !void {
        self.lock.lock(self.io);
        defer self.lock.unlock(self.io);

        const id = ctr.id[0..];
        try self.by_id.put(id, ctr);
        try self.by_name.put(ctr.name, id);
    }

    pub fn get(self: *ContainerStore, id_or_prefix: []const u8) ?*Container {
        self.lock.lockShared(self.io);
        defer self.lock.unlockShared(self.io);

        if (self.by_id.get(id_or_prefix)) |ctr| return ctr;

        if (self.by_name.get(id_or_prefix)) |id| {
            return self.by_id.get(id);
        }

        // Prefix match: scan all IDs, return null on ambiguity
        var match: ?*Container = null;
        var it = self.by_id.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, id_or_prefix)) {
                if (match != null) return null;
                match = entry.value_ptr.*;
            }
        }
        return match;
    }

    pub fn delete(self: *ContainerStore, id: []const u8) void {
        self.lock.lock(self.io);
        defer self.lock.unlock(self.io);

        if (self.by_id.fetchRemove(id)) |entry| {
            _ = self.by_name.remove(entry.value.name);
        }
    }

    pub fn list(self: *ContainerStore, allocator: std.mem.Allocator) ![]*Container {
        self.lock.lockShared(self.io);
        defer self.lock.unlockShared(self.io);

        var result = try std.ArrayList(*Container).initCapacity(allocator, self.by_id.count());

        var it = self.by_id.valueIterator();
        while (it.next()) |ctr| result.appendAssumeCapacity(ctr.*);
        return try result.toOwnedSlice();
    }

    pub fn loadFromDisk(self: *ContainerStore, data_root: []const u8, allocator: std.mem.Allocator) !void {
        var path_buf: [512]u8 = undefined;
        const containers_dir = try std.fmt.bufPrint(&path_buf, "{s}/containers", .{data_root});

        var dir = std.Io.Dir.openDirAbsolute(self.io, containers_dir, .{ .iterate = true }) catch |err| {
            if (err == openError.FileNotFound) return;
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

            try self.add(ctr);
        }
    }
};

pub const LoadError = error{
    InvalidJson,
    MissingId,
    MissingName,
};

fn loadContainerFromFile(io: std.Io, path: []const u8, allocator: std.mem.Allocator) !*Container {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    const content = try file.reader(io, &read_buf).readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return LoadError.InvalidJson,
    };

    const ctr = try allocator.create(Container);
    errdefer allocator.destroy(ctr);

    ctr.io = io;
    ctr.mutex = .{};

    // ID
    const id_val = root.get("ID") orelse root.get("Id") orelse return LoadError.MissingId;
    const id_str = id_val.string;
    @memset(&ctr.id, 0);
    const id_copy_len = @min(id_str.len, 64);
    @memcpy(ctr.id[0..id_copy_len], id_str[0..id_copy_len]);
    @memset(&ctr.id_short, 0);
    @memcpy(&ctr.id_short, ctr.id[0..12]);

    // Name
    const name_val = root.get("Name") orelse return LoadError.MissingName;
    ctr.name = try allocator.dupe(u8, name_val.string);

    ctr.created_at = if (root.get("Created")) |c| c.integer else 0;

    ctr.image_id = try allocator.dupe(u8, if (root.get("Image")) |v| v.string else "");
    ctr.image_name = try allocator.dupe(u8, if (root.get("ImageName")) |v| v.string else "");

    ctr.rw_layer_id = try allocator.dupe(u8, if (root.get("RwLayerID")) |v| v.string else "");
    ctr.rootfs_paths = try allocator.dupe(u8, if (root.get("RootfsPath")) |v| v.string else "");

    ctr.log_path = try allocator.dupe(u8, if (root.get("LogPath")) |v| v.string else "");
    ctr.log_driver = if (root.get("LogDriver")) |v| try allocator.dupe(u8, v.string) else "json-file";

    ctr.state = parseState(root.get("State"));

    ctr.config = try parseConfig(root.get("Config"), allocator);

    ctr.host_config = .{
        .port_bindings = std.StringHashMap([]PortBinding).init(allocator),
    };

    ctr.network_settings = .{
        .networks = std.StringHashMap(EndpointSettings).init(allocator),
        .ports = std.StringHashMap([]PortBinding).init(allocator),
    };

    ctr.exec_commands = std.StringHashMap(*ExecProcess).init(allocator);

    return ctr;
}

fn parseState(val: ?std.json.Value) ContainerState {
    var state = ContainerState{ .exit_code = 0 };

    const obj = switch (val orelse return state) {
        .object => |o| o,
        else => return state,
    };

    if (obj.get("Status")) |s| {
        state.status = std.meta.stringToEnum(ContainerState.Status, s.string) orelse .exited;
    }
    if (obj.get("Running")) |v| state.running = v.bool;
    if (obj.get("Paused")) |v| state.paused = v.bool;
    if (obj.get("Restarting")) |v| state.restarting = v.bool;
    if (obj.get("OOMKilled")) |v| state.oom_killed = v.bool;
    if (obj.get("Dead")) |v| state.dead = v.bool;
    if (obj.get("Pid")) |v| state.pid = @intCast(v.integer);
    if (obj.get("ExitCode")) |v| state.exit_code = @intCast(v.integer);
    if (obj.get("StartedAt")) |v| state.started_at = v.integer;
    if (obj.get("FinishedAt")) |v| state.finished_at = v.integer;

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

    if (obj.get("Image")) |v| cfg.image = try allocator.dupe(u8, v.string);
    if (obj.get("WorkingDir")) |v| cfg.working_dir = try allocator.dupe(u8, v.string);
    if (obj.get("User")) |v| cfg.user = try allocator.dupe(u8, v.string);
    if (obj.get("Tty")) |v| cfg.tty = v.bool;
    if (obj.get("OpenStdin")) |v| cfg.open_stdin = v.bool;
    if (obj.get("StopSignal")) |v| cfg.stop_signal = try allocator.dupe(u8, v.string);
    if (obj.get("StopTimeout")) |v| cfg.stop_timeout = @intCast(v.integer);

    if (obj.get("Cmd")) |v| cfg.cmd = try parseStringArray(v, allocator);
    if (obj.get("Entrypoint")) |v| cfg.entrypoint = try parseStringArray(v, allocator);
    if (obj.get("Env")) |v| cfg.env = try parseStringArray(v, allocator);

    if (obj.get("Labels")) |labels_val| {
        if (labels_val == .object) {
            var label_it = labels_val.object.iterator();
            while (label_it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const lval = try allocator.dupe(u8, entry.value_ptr.*.string);
                try cfg.labels.put(key, lval);
            }
        }
    }

    return cfg;
}

fn parseStringArray(val: std.json.Value, allocator: std.mem.Allocator) ![]const []const u8 {
    const arr = switch (val) {
        .array => |a| a,
        else => return &.{},
    };
    const result = try allocator.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        result[i] = try allocator.dupe(u8, item.string);
    }
    return result;
}
