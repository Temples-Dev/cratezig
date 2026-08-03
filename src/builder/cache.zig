const std = @import("std");

pub const BuildCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap([]const u8),
    lock: std.Io.RwLock = .init,

    pub fn init(allocator: std.mem.Allocator) BuildCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *BuildCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn computeKey(allocator: std.mem.Allocator, parent_id: []const u8, instruction_raw: []const u8, context_hash: []const u8) ![]const u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(parent_id);
        hasher.update(":");
        hasher.update(instruction_raw);
        hasher.update(":");
        hasher.update(context_hash);

        var digest: [32]u8 = undefined;
        hasher.final(&digest);

        var hex: [64]u8 = undefined;
        @memcpy(&hex, std.fmt.bytesToHex(digest, .lower)[0..64]);
        return try std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
    }

    pub fn get(self: *BuildCache, io: std.Io, key: []const u8) ?[]const u8 {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.entries.get(key);
    }

    pub fn put(self: *BuildCache, io: std.Io, key: []const u8, layer_id: []const u8) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const val_copy = try self.allocator.dupe(u8, layer_id);
        errdefer self.allocator.free(val_copy);

        if (try self.entries.fetchPut(key_copy, val_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }
};

test "compute key and cache lookup" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var cache = BuildCache.init(alloc);
    defer cache.deinit();

    const key = try BuildCache.computeKey(alloc, "parent123", "RUN echo hello", "ctx456");
    defer alloc.free(key);

    try std.testing.expect(cache.get(io, key) == null);

    try cache.put(io, key, "layer789");
    const hit = cache.get(io, key);
    try std.testing.expect(hit != null);
    try std.testing.expectEqualStrings("layer789", hit.?);
}
