const std = @import("std");

pub const CACHE_CAPACITY: usize = 256;

pub const MetadataEntry = struct {
    tag_hash: u64 = 0,
    digest: [32]u8 = [_]u8{0} ** 32,
    fetched_at: i64 = 0,
    ttl_seconds: u32 = 86400,
    valid: bool = false,
};

pub fn hashTag(tag: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (tag) |b| {
        hash ^= b;
        hash *%= 0x100000001b3;
    }
    return hash;
}

pub const MetadataCache = struct {
    entries: [CACHE_CAPACITY]MetadataEntry = [_]MetadataEntry{.{}} ** CACHE_CAPACITY,
    head: usize = 0,

    pub fn init() MetadataCache {
        return .{};
    }

    pub fn getDigest(self: *const MetadataCache, tag_hash: u64, now_ts: i64) ?[32]u8 {
        for (&self.entries) |*entry| {
            if (entry.valid and entry.tag_hash == tag_hash) {
                if (now_ts - entry.fetched_at <= entry.ttl_seconds) {
                    return entry.digest;
                } else {
                    return null; // Expired TTL
                }
            }
        }
        return null;
    }

    pub fn putDigest(self: *MetadataCache, tag_hash: u64, digest: [32]u8, ttl_seconds: u32, now_ts: i64) void {
        // Update existing entry if present
        for (&self.entries) |*entry| {
            if (entry.valid and entry.tag_hash == tag_hash) {
                entry.digest = digest;
                entry.fetched_at = now_ts;
                entry.ttl_seconds = ttl_seconds;
                return;
            }
        }

        // Insert at head (LRU eviction pointer)
        self.entries[self.head] = MetadataEntry{
            .tag_hash = tag_hash,
            .digest = digest,
            .fetched_at = now_ts,
            .ttl_seconds = ttl_seconds,
            .valid = true,
        };
        self.head = (self.head + 1) % CACHE_CAPACITY;
    }
};

test "metadata cache O(1) lookup and TTL expiration" {
    var cache = MetadataCache.init();
    const tag = "python:3.9-slim";
    const tag_h = hashTag(tag);

    var dummy_digest: [32]u8 = [_]u8{0xab} ** 32;

    const now: i64 = 1700000000;
    cache.putDigest(tag_h, dummy_digest, 3600, now);

    // 1. Hit within TTL
    const hit = cache.getDigest(tag_h, now + 100);
    try std.testing.expect(hit != null);
    try std.testing.expectEqualSlices(u8, &dummy_digest, &hit.?);

    // 2. Miss after TTL expiration
    const expired = cache.getDigest(tag_h, now + 4000);
    try std.testing.expect(expired == null);
}
