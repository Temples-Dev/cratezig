const std = @import("std");

const Container = @import("container.zig").Container;

const openError = std.Io.Dir.OpenError;

pub const ContainerStore = struct {
    io: std.Io,

    allocator: std.mem.Allocator,

    lock: std.Io.RwLock = .{},

    by_id: std.StringHashMap(*Container),

    by_name: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ContainerStore {
        return .{ .io = io, .allocator = allocator, .by_id = std.StringHashMap(*Container).init(allocator), .by_name = std.StringHashMap(*Container).init(allocator) };
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

        if (self.by_id.get(id_or_prefix)) |ctr| return ctr; // getting the container through the id

        if (self.by_name.get(id_or_prefix)) |id| {
            return self.by_id.get(id); // returns containers id through the name hash
        }

        //Prefix match: scan all IDs for unique prefix

        var match: ?*Container = null;
        var it = self.by_id.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, id_or_prefix)) {
                if (match != null) return null; // why should a !null match return null?
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
        result.toOwnedSlice(allocator);
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

            const ctr = loadContainerFromFile(config_path, allocator) catch |err| { // loadContainerFromFile not defined yet
                std.log.warn("failed to load container {s}: {}", .{ entry.name, err });
                continue;
            };

            try self.add(ctr);
        }
    }

    // pub fn loadContainerFromFile(self: *ContainerStore, data_root: []const u8, allocator: std.mem.Allocator) !void {}
};
